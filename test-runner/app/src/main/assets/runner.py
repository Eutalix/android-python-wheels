import sys
import os
import urllib.request
import zipfile
import traceback

def main():
    print("--- STARTING E2E NATIVE ANDROID TEST ---")
    
    if len(sys.argv) < 3:
        print(">>> TEST_FAILED_MARKER: Missing arguments! <<<")
        sys.exit(1)

    download_url = sys.argv[1]
    package_name = sys.argv[2]
    
    base_dir = os.path.dirname(os.path.abspath(__file__))
    site_packages = os.path.join(base_dir, "site-packages")
    os.makedirs(site_packages, exist_ok=True)
    sys.path.insert(0, site_packages)

    wheel_path = os.path.join(base_dir, "temp.whl")

    try:
        print(f"Downloading wheel from: {download_url}")
        urllib.request.urlretrieve(download_url, wheel_path)

        print("Extracting wheel...")
        with zipfile.ZipFile(wheel_path, 'r') as zip_ref:
            zip_ref.extractall(site_packages)
        
        os.remove(wheel_path)

        print(f"Attempting to import native library: {package_name}")
        module = __import__(package_name)
        
        version = getattr(module, '__version__', 'Unknown')
        print(f"Success! Loaded version: {version}")
        print(">>> TEST_SUCCESS_MARKER <<<")

    except Exception as e:
        print(f">>> TEST_FAILED_MARKER: {e} | Traceback: {traceback.format_exc()} <<<")

if __name__ == "__main__":
    main()