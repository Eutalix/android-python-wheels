# ⚙️ Android Python Wheels

[![CI/CD Pipeline](https://github.com/Eutalix/android-python-wheels/actions/workflows/build-wheels.yml/badge.svg)](https://github.com/Eutalix/android-python-wheels/actions)
[![Deploy Pages](https://github.com/Eutalix/android-python-wheels/actions/workflows/publish-index.yml/badge.svg)](https://github.com/Eutalix/android-python-wheels/actions)

A fully automated, self-healing CI/CD pipeline that cross-compiles and serves native Python C/Rust extensions (`.whl`) for Android devices.

This repository acts as an **Android-specific Wheelhouse**, providing pre-built, optimized binaries for complex packages (like `brotli`, `pycryptodomex`, `pydantic-core`) that are otherwise difficult to compile on mobile devices.

## 🎯 The Problem it Solves
Running Python on Android (via Chaquopy, Kivy/p4a, or native JNI) is great, but compiling C/C++ or Rust dependencies directly on the user's device is impossible. Including heavy native compilation steps in your main app's CI drastically increases build times and maintenance overhead.

Furthermore, modern Android versions (API 29+) enforce strict security namespaces (`W^X`, `dlopen` restrictions). Standard wheels often crash silently with `Library not found` errors when attempting to load shared C libraries.

## ✨ Our Solution
This repository completely decouples native dependency building from your app's main engine.
* **Fully Automated:** A daily cron job watches PyPI for updates, triggering cross-compilation via the Android NDK and Rust targets.
* **Linker-Safe:** We automatically inject `$ORIGIN` into the ELF headers (via `patchelf`) of all binaries. This guarantees that `dlopen` will successfully link modules like `zlib` and `libpython` regardless of the Android security namespace.
* **QA Tested:** Before any wheel is published, it is installed and executed inside a native Android KVM Emulator running on our GitHub Actions pipeline to ensure zero runtime crashes.
* **Multi-Architecture:** Generates wheels for `arm64-v8a`, `armeabi-v7a`, `x86`, and `x86_64` across Python versions `3.9` through `3.13`.

---

## 🚀 How to Consume (For App Developers)

We serve the pre-built wheels via GitHub Pages. We offer two endpoints depending on your use case:

### 1. The Mobile JSON API (Recommended for Android Runtime)
Instead of parsing complex HTML, your Kotlin/Java app can fetch an ultra-lightweight (1KB) `index.json` file for specific packages to determine the exact download URL for the user's device architecture.

**Endpoint:** `https://Eutalix.github.io/android-python-wheels/<package_name>/index.json`

**Example Kotlin Implementation:**
```kotlin
val myArch = "arm64-v8a" // e.g., Build.SUPPORTED_ABIS[0]
val myPyVer = "cp311"

// Fetch the JSON
val jsonString = URL("https://Eutalix.github.io/android-python-wheels/brotli/index.json").readText()
val json = JSONObject(jsonString)

// Find the right wheel URL dynamically
val latestVer = json.getString("latest_version")
val downloadUrl = json.getJSONObject("versions")
                      .getJSONObject(latestVer)
                      .getJSONObject(myPyVer)
                      .getString(myArch)

// Download and extract to your app's site-packages!
downloadFile(downloadUrl)
```

### 2. PEP 503 Simple Index (For CI/CD `pip`)
If you are building your Android engine in your own CI and want `pip` to automatically grab the Android wheels instead of building from source, simply add our repository as an extra index url:

```bash
pip install brotli \
  --extra-index-url https://Eutalix.github.io/android-python-wheels/simple/
```

---

## 📦 Currently Supported Packages
* `brotli` (Crucial for bypassing network throttling in tools like yt-dlp)
* `pycryptodomex` (DRM and signature decryption)
* *(More packages can be easily added via PR)*

## 🛠️ Repository Architecture

1. **The Watcher (`check_updates.py`):** Checks PyPI daily. If a new version drops, it triggers the factory.
2. **The Factory (`build-wheels.yml`):** Spins up a 20-container matrix to cross-compile the C/Rust code against the NDK. Uploads results to a staging bin.
3. **The QA Inspector (`test-wheel.yml`):** Downloads the staging wheels into a headless Android Emulator. Uses a custom Kotlin shell app to dynamically load the C-extension.
4. **The Publisher (`publish-index.yml`):** If the emulator approves the wheel, it is promoted to production and the GitHub Pages API is regenerated.

## 🤝 Contributing
Want to add a new package? 
1. Create a new folder under `build-wheels/` with the package name.
2. Add a `build.sh` script mapping the specific C or Rust compiler flags (you can copy the boilerplate from existing packages).
3. Add the package to the `PACKAGES` dictionary in `scripts/check_updates.py`.
4. Open a Pull Request!

## License
MIT License. See [LICENSE](LICENSE) for more information.