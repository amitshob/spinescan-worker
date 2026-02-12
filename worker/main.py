import os, time, tempfile, zipfile, shutil
import requests
from supabase import create_client

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "10"))

BUCKET_ZIPS = os.environ.get("BUCKET_ZIPS", "scan-zips")
BUCKET_RESULTS = os.environ.get("BUCKET_RESULTS", "scan-results")

supabase = create_client(SUPABASE_URL, SERVICE_KEY)

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

def download_private_zip(zip_path: str, dst_file: str):
    # Signed URL is easiest + reliable for private buckets
    signed = (
        supabase.storage
        .from_(BUCKET_ZIPS)
        .create_signed_url(zip_path, 60, {"download": True})
    )
    url = signed["signedURL"]

    r = requests.get(url, timeout=180)
    r.raise_for_status()
    with open(dst_file, "wb") as f:
        f.write(r.content)

def main():
    print("Worker started. Polling every", POLL_SECONDS, "seconds.")
    while True:
        job = pick_next_uploaded()
        if not job:
            time.sleep(POLL_SECONDS)
            continue

        scan_id = job["id"]
        zip_path = job.get("zip_path")
        user_id = job.get("user_id")

        if not zip_path:
            mark(scan_id, "failed", error="Missing zip_path")
            continue

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

            # MVP plumbing checkpoint: verify images exist
            jpg_count = 0
            for root, _, files in os.walk(extract_dir):
                for name in files:
                    if name.lower().endswith(".jpg"):
                        jpg_count += 1

            print("Extracted JPGs:", jpg_count)

            # Placeholder "result" until COLMAP/OpenMVS is added
            # We'll later upload STL to scan-results and set stl_path.
            mark(scan_id, "complete", stl_path=None, error=f"PLUMBING_OK: extracted {jpg_count} jpgs (no reconstruction yet)")
            print("Marked complete (plumbing ok):", scan_id)

        except Exception as e:
            print("FAILED:", scan_id, str(e))
            mark(scan_id, "failed", error=str(e))
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

if __name__ == "__main__":
    main()

