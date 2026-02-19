import os
import time
import tempfile
import zipfile
import shutil
import subprocess
import signal
import requests
from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "10"))

BUCKET_ZIPS = os.environ.get("BUCKET_ZIPS", "scan-zips")
BUCKET_RESULTS = os.environ.get("BUCKET_RESULTS", "scan-results")

# How much pipeline output to keep in DB (avoid giant rows)
MAX_LOG_CHARS = int(os.environ.get("MAX_LOG_CHARS", "20000"))

supabase = create_client(SUPABASE_URL, SERVICE_KEY)

# Track current scan so we can mark it failed if the worker is killed (OOM / SIGTERM).
CURRENT_SCAN_ID = None


def pick_next_uploaded():
    resp = (
        supabase.table("scans")
        .select("*")
        .eq("status", "uploaded")
        .order("created_at", desc=False)
        .limit(1)
        .execute()
    )
    rows = resp.data or []
    return rows[0] if rows else None


def mark(scan_id: str, status: str, **fields):
    payload = {"status": status, **fields}
    supabase.table("scans").update(payload).eq("id", scan_id).execute()


def _handle_termination(signum, frame):
    global CURRENT_SCAN_ID
    # Best-effort: mark the scan as failed if we are being terminated (often due to OOM).
    if CURRENT_SCAN_ID:
        try:
            mark(
                CURRENT_SCAN_ID,
                "failed",
                error="Worker terminated (SIGTERM/SIGINT). Likely OOM / memory limit.",
            )
            print(f"Marked scan failed due to termination: {CURRENT_SCAN_ID}", flush=True)
        except Exception as e:
            print(f"Failed to mark scan failed on termination: {e}", flush=True)
    raise SystemExit(1)


signal.signal(signal.SIGTERM, _handle_termination)
signal.signal(signal.SIGINT, _handle_termination)


def download_private_zip(zip_path: str, dst_file: str):
    signed = (
        supabase.storage
        .from_(BUCKET_ZIPS)
        .create_signed_url(zip_path, 300, {"download": True})
    )
    url = signed["signedURL"]

    r = requests.get(url, timeout=300)
    r.raise_for_status()
    with open(dst_file, "wb") as f:
        f.write(r.content)


def upload_result_stl(local_file: str, remote_path: str):
    # Upload bytes to avoid any file-handle API mismatch.
    with open(local_file, "rb") as f:
        data = f.read()

    res = supabase.storage.from_(BUCKET_RESULTS).upload(
        remote_path,
        data,
        {"content-type": "model/stl", "upsert": True},
    )

    # Some client versions return dicts; fail loudly if there's an explicit error.
    if isinstance(res, dict) and res.get("error"):
        raise RuntimeError(f"STL upload failed: {res['error']}")

    # Verify object exists
    folder = os.path.dirname(remote_path)
    listed = supabase.storage.from_(BUCKET_RESULTS).list(folder)
    names = [o.get("name") for o in (listed or [])]
    if "result.stl" not in names:
        raise RuntimeError("STL upload verification failed: result.stl not found in scan-results")


def run_pipeline_capture(images_dir: str, out_dir: str) -> str:
    """
    Runs pipeline.sh, streams output to Render logs, and returns full combined log.
    """
    script = os.path.join(os.path.dirname(__file__), "pipeline.sh")
    cmd = ["bash", script, images_dir, out_dir]
    print(f"[worker] Running pipeline: {' '.join(cmd)}", flush=True)

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,  # line-buffered
        universal_newlines=True,
    )

    lines = []
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.rstrip("\n")
        print(line, flush=True)   # appears in Render runtime logs
        lines.append(line)

        # keep memory bounded if log is huge
        if sum(len(x) + 1 for x in lines) > (MAX_LOG_CHARS * 2):
            # drop oldest half
            lines = lines[len(lines)//2 :]

    rc = proc.wait()
    log_text = "\n".join(lines)
    if rc != 0:
        raise RuntimeError(f"pipeline exited with code {rc}")
    return log_text


def convert_to_stl(mesh_ply: str, out_stl: str):
    converter = os.path.join(os.path.dirname(__file__), "convert_to_stl.py")
    subprocess.run(["python3", converter, mesh_ply, out_stl], check=True)


def count_jpgs(folder: str) -> int:
    c = 0
    for root, _, files in os.walk(folder):
        for name in files:
            n = name.lower()
            if n.endswith(".jpg") or n.endswith(".jpeg"):
                c += 1
    return c


def safe_update_log(scan_id: str, log_text: str):
    """
    Best-effort: store logs in scans.log_text if column exists.
    If the column doesn't exist yet, silently ignore.
    """
    try:
        supabase.table("scans").update(
            {"log_text": log_text[-MAX_LOG_CHARS:]}
        ).eq("id", scan_id).execute()
    except Exception as e:
        # Likely column missing or RLS; ignore so we don't mask real errors
        print(f"[worker] Could not write log_text to scans table: {e}", flush=True)


def main():
    global CURRENT_SCAN_ID
    print("Worker started. Polling every", POLL_SECONDS, "seconds.", flush=True)

    while True:
        job = pick_next_uploaded()
        if not job:
            time.sleep(POLL_SECONDS)
            continue

        scan_id = job["id"]
        zip_path = job.get("zip_path")
        user_id = job.get("user_id")

        if not zip_path or not user_id:
            mark(scan_id, "failed", error="Missing zip_path or user_id")
            continue

        CURRENT_SCAN_ID = scan_id
        tmpdir = tempfile.mkdtemp(prefix="spinescan_")
        pipeline_log = ""

        try:
            print("Claiming scan:", scan_id, flush=True)
            mark(scan_id, "processing", error=None)

            zip_file = os.path.join(tmpdir, "scan.zip")
            print("Downloading:", zip_path, flush=True)
            download_private_zip(zip_path, zip_file)

            extract_dir = os.path.join(tmpdir, "extract")
            os.makedirs(extract_dir, exist_ok=True)
            with zipfile.ZipFile(zip_file, "r") as z:
                z.extractall(extract_dir)

            jpg_count = count_jpgs(extract_dir)
            print("Extracted JPGs:", jpg_count, flush=True)

            out_dir = os.path.join(tmpdir, "out")
            os.makedirs(out_dir, exist_ok=True)

            print("Running reconstruction pipeline...", flush=True)
            pipeline_log = run_pipeline_capture(extract_dir, out_dir)

            # Store pipeline log even on success (for debugging/traceability)
            safe_update_log(scan_id, pipeline_log)

            mesh_ply = os.path.join(out_dir, "mesh.ply")
            if not os.path.exists(mesh_ply):
                raise RuntimeError("mesh.ply not created")

            out_stl = os.path.join(out_dir, "result.stl")
            print("Converting to STL...", flush=True)
            convert_to_stl(mesh_ply, out_stl)

            if not os.path.exists(out_stl):
                raise RuntimeError("result.stl not created")

            remote_stl_path = f"users/{str(user_id).lower()}/{str(scan_id).lower()}/result.stl"
            print("Uploading STL to:", remote_stl_path, flush=True)
            upload_result_stl(out_stl, remote_stl_path)

            mark(scan_id, "complete", stl_path=remote_stl_path, error=None)
            print("COMPLETE:", scan_id, flush=True)

        except Exception as e:
            # Save pipeline log to DB for debugging
            if pipeline_log:
                safe_update_log(scan_id, pipeline_log)

            # If this was a pipeline failure, include tail of log in error for quick glance
            tail = ""
            if pipeline_log:
                tail = pipeline_log[-2000:].replace("\n", " | ")
            msg = f"{e}"
            if tail:
                msg = f"{msg} | tail: {tail}"

            print("FAILED:", scan_id, msg, flush=True)
            mark(scan_id, "failed", error=msg[:2000])

        finally:
            CURRENT_SCAN_ID = None
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
