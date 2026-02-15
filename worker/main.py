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
            mark(CURRENT_SCAN_ID, "failed", error="Worker terminated (SIGTERM/SIGINT). Likely OOM / memory limit.")
            print(f"Marked scan failed due to termination: {CURRENT_SCAN_ID}")
        except Exception as e:
            print(f"Failed to mark scan failed on termination: {e}")
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


def run_pipeline(images_dir: str, out_dir: str):
    script = os.path.join(os.path.dirname(__file__), "pipeline.sh")
    subprocess.run(["bash", script, images_dir, out_dir], check=True)


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


def main():
    global CURRENT_SCAN_ID
    print("Worker started. Polling every", POLL_SECONDS, "seconds.")
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

        try:
            print("Claiming scan:", scan_id)
            mark(scan_id, "processing", error=None)

            zip_file = os.path.join(tmpdir, "scan.zip")
            print("Downloading:", zip_path)
            download_private_zip(zip_path, zip_file)

            extract_dir = os.path.join(tmpdir, "extract")
            os.makedirs(extract_dir, exist_ok=True)
            with zipfile.ZipFile(zip_file, "r") as z:
                z.extractall(extract_dir)

            jpg_count = count_jpgs(extract_dir)
            print("Extracted JPGs:", jpg_count)

            images_dir = extract_dir
            out_dir = os.path.join(tmpdir, "out")
            os.makedirs(out_dir, exist_ok=True)

            print("Running COLMAP pipeline...")
            run_pipeline(images_dir, out_dir)

            mesh_ply = os.path.join(out_dir, "mesh.ply")
            if not os.path.exists(mesh_ply):
                raise RuntimeError("mesh.ply not created")

            out_stl = os.path.join(out_dir, "result.stl")
            print("Converting to STL...")
            convert_to_stl(mesh_ply, out_stl)

            if not os.path.exists(out_stl):
                raise RuntimeError("result.stl not created")

            remote_stl_path = f"users/{str(user_id).lower()}/{str(scan_id).lower()}/result.stl"
            print("Uploading STL to:", remote_stl_path)
            upload_result_stl(out_stl, remote_stl_path)

            mark(scan_id, "complete", stl_path=remote_stl_path, error=None)
            print("COMPLETE:", scan_id)

        except subprocess.CalledProcessError as e:
            msg = f"Pipeline failed: {e}"
            print("FAILED:", scan_id, msg)
            mark(scan_id, "failed", error=msg)

        except Exception as e:
            msg = str(e)
            print("FAILED:", scan_id, msg)
            mark(scan_id, "failed", error=msg)

        finally:
            CURRENT_SCAN_ID = None
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
