import urllib.request
import urllib.error
import json
import os
import subprocess
import sys

# Master dictionary: Maps the PyPI package name to its Python import name (used by the QA Emulator)
PACKAGES = {
    "brotli": "brotli",
    "pycryptodomex": "Cryptodome"
}

REPO = os.environ.get("GITHUB_REPOSITORY")
TOKEN = os.environ.get("GITHUB_TOKEN")

if not REPO or not TOKEN:
    print("❌ REPO or TOKEN environment variables are missing.")
    sys.exit(1)

def get_latest_pypi_version(pkg):
    url = f"https://pypi.org/pypi/{pkg}/json"
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            return data["info"]["version"]
    except Exception as e:
        print(f"⚠️ Failed to fetch PyPI data for {pkg}: {e}")
        return None

def get_built_versions(pkg):
    url = f"https://api.github.com/repos/{REPO}/releases/tags/wheel-{pkg}"
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {TOKEN}")
    req.add_header("Accept", "application/vnd.github.v3+json")
    
    try:
        with urllib.request.urlopen(req) as response:
            data = json.loads(response.read().decode())
            versions = set()
            for asset in data.get("assets", []):
                name = asset["name"]
                if name.endswith(".whl"):
                    # Extract version from wheel name (e.g., brotli-1.2.0-...)
                    parts = name.split("-")
                    if len(parts) >= 2:
                        versions.add(parts[1])
            return versions
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return set() # Release doesn't exist yet, meaning it's a completely new package
        print(f"⚠️ Failed to fetch GitHub releases for {pkg}: HTTP {e.code}")
        return set()

if __name__ == "__main__":
    updates_triggered = False

    for pkg, import_name in PACKAGES.items():
        print(f"🔍 Checking {pkg}...")
        
        latest_version = get_latest_pypi_version(pkg)
        if not latest_version:
            continue
            
        built_versions = get_built_versions(pkg)
        
        if latest_version not in built_versions:
            print(f"🚀 New version found for {pkg}: {latest_version} (Built: {built_versions})")
            print(f"   Triggering build pipeline...")
            
            # Fire the GitHub Actions Build Workflow using gh cli
            cmd = [
                "gh", "workflow", "run", "build-wheels.yml",
                "-f", f"package={pkg}",
                "-f", f"import_name={import_name}"
            ]
            
            try:
                subprocess.run(cmd, check=True)
                print(f"✅ Pipeline triggered successfully for {pkg}.")
                updates_triggered = True
            except subprocess.CalledProcessError as e:
                print(f"❌ Failed to trigger pipeline for {pkg}: {e}")
        else:
            print(f"✅ {pkg} is up to date (Version {latest_version}).")

    if not updates_triggered:
        print("💤 No updates needed today.")