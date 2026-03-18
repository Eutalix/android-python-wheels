import urllib.request
import json
import os
import sys

REPO = os.environ.get("GITHUB_REPOSITORY")
if not REPO:
    print("❌ REPO environment variable not set.")
    sys.exit(1)

print(f"🔍 Fetching releases from API for {REPO}...")

cmd = ["gh", "api", f"repos/{REPO}/releases", "--paginate"]
import subprocess
result = subprocess.run(cmd, capture_output=True, text=True)

if result.returncode != 0:
    print(f"❌ API Error: {result.stderr}")
    sys.exit(1)

releases = json.loads(result.stdout)

# Mapping Linux compilation tags to Android standard naming convention
ARCH_MAP = {
    "linux_aarch64": "arm64-v8a",
    "linux_armv7l": "armeabi-v7a",
    "linux_i686": "x86",
    "linux_x86_64": "x86_64"
}

db_json = {"packages": {}}
html_links = {}
wheel_count = 0

for release in releases:
    tag_name = release.get('tag_name', '')
    
    # Ignore infrastructure tags
    if tag_name in ['staging-wheels', 'test-runners', 'python-test-cores'] or release.get('draft'):
        continue
        
    for asset in release.get('assets', []):
        name = asset['name']
        download_url = asset.get('browser_download_url')
        
        if name.endswith('.whl') and download_url:
            # Parse Wheel name: pkg-version-pyTag-abiTag-platform.whl
            parts = name[:-4].split('-')
            if len(parts) < 5:
                continue
                
            pkg_name = parts[0].lower().replace('_', '-')
            version = parts[1]
            py_tag = parts[2] # e.g., cp311
            plat_tag = parts[4] # e.g., linux_aarch64
            
            android_arch = ARCH_MAP.get(plat_tag, plat_tag)

            # ---- 1. BUILD HTML DATA ----
            if pkg_name not in html_links:
                html_links[pkg_name] = []
            html_links[pkg_name].append(f'<a href="{download_url}">{name}</a>')

            # ---- 2. BUILD JSON DATA ----
            if pkg_name not in db_json["packages"]:
                db_json["packages"][pkg_name] = {"latest_version": version, "versions": {}}
            
            if version not in db_json["packages"][pkg_name]["versions"]:
                db_json["packages"][pkg_name]["versions"][version] = {}
                
            if py_tag not in db_json["packages"][pkg_name]["versions"][version]:
                db_json["packages"][pkg_name]["versions"][version][py_tag] = {}
                
            # Maps the exact URL to its target architecture and python version
            db_json["packages"][pkg_name]["versions"][version][py_tag][android_arch] = download_url
            db_json["packages"][pkg_name]["latest_version"] = version
            wheel_count += 1

# Geração Física (Physical Generation)
os.makedirs("site", exist_ok=True)

root_links = []
for pkg_name, links in html_links.items():
    pkg_dir = f"site/{pkg_name}"
    os.makedirs(pkg_dir, exist_ok=True)
    
    # 1. HTML Index (PEP 503 compatible for PIP)
    with open(f"{pkg_dir}/index.html", "w") as f:
        f.write(f"<!DOCTYPE html>\n<html><body><h1>Links for {pkg_name}</h1>\n" + "<br>\n".join(links) + "\n</body></html>")
    
    # 2. JSON Index (Ultra-light API for Kotlin Mobile Clients)
    pkg_data = db_json["packages"][pkg_name]
    with open(f"{pkg_dir}/index.json", "w") as f:
        json.dump(pkg_data, f, indent=2)
        
    root_links.append(f'<a href="{pkg_name}/">{pkg_name}</a>')

with open("site/index.html", "w") as f:
    f.write("<!DOCTYPE html>\n<html><body><h1>Android Python Wheels Index</h1>\n" + "<br>\n".join(root_links) + "\n</body></html>")

print(f"✅ Generated PEP 503 and JSON Index for {wheel_count} wheels.")