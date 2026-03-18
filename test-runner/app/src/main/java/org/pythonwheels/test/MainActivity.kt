package org.pythonwheels.test

import android.app.Activity
import android.os.Bundle
import android.system.Os
import android.util.Log
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.util.zip.ZipInputStream
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private val TAG = "PythonRunner"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        val wheelUrl = intent.getStringExtra("WHEEL_URL") ?: ""
        val packageName = intent.getStringExtra("PACKAGE_NAME") ?: ""

        if (wheelUrl.isEmpty()) {
            Log.e(TAG, ">>> TEST_FAILED_MARKER: WHEEL_URL missing from Intent! <<<")
            return
        }

        thread {
            try {
                Log.i(TAG, ">>> Initializing Native Environment with Universal Symlinks... <<<")
                
                val runnerScript = File(filesDir, "runner.py")
                copyAsset("runner.py", runnerScript)
                
                val nativeDir = File(applicationInfo.nativeLibraryDir)
                val pythonExe = File(nativeDir, "libpython.so")
                val stdlibZip = File(nativeDir, "libpython.zip.so")

                // 1. Extract base C-Extensions (zlib, math)
                val modulesDir = File(filesDir, "modules")
                if (!modulesDir.exists() || modulesDir.listFiles()?.isEmpty() == true) {
                    extractZipFromAssets("modules.zip", modulesDir)
                }

                // 2. Ensure site-packages exists
                val sitePackagesDir = File(filesDir, "site-packages")
                sitePackagesDir.mkdirs()

                // 3. Absolute Target for Python 3.11 Guardian
                val realPythonLib = File(nativeDir, "libpython3.11.so")
                if (!realPythonLib.exists()) {
                    Log.e(TAG, ">>> TEST_FAILED_MARKER: ${realPythonLib.absolutePath} not found! <<<")
                    return@thread
                }
                
                // 4. Symlink trick to bypass Android Linker namespace constraints
                val pythonLibInModules = File(modulesDir, "libpython3.11.so")
                val pythonLibInSitePackages = File(sitePackagesDir, "libpython3.11.so")
                
                try {
                    if (!pythonLibInModules.exists()) Os.symlink(realPythonLib.absolutePath, pythonLibInModules.absolutePath)
                    if (!pythonLibInSitePackages.exists()) Os.symlink(realPythonLib.absolutePath, pythonLibInSitePackages.absolutePath)
                } catch (e: Exception) {
                    Log.w(TAG, "Symlink warning: ${e.message}")
                }

                val command = listOf(
                    pythonExe.absolutePath,
                    runnerScript.absolutePath,
                    wheelUrl,
                    packageName
                )
                
                val processBuilder = ProcessBuilder(command)

                // 5. Environment Setup
                val env = processBuilder.environment()
                
                val systemLd = System.getenv("LD_LIBRARY_PATH") ?: ""
                env["LD_LIBRARY_PATH"] = "${nativeDir.absolutePath}:$systemLd"
                env["JAVA_LIBRARY_PATH"] = nativeDir.absolutePath
                env["jna.library.path"] = nativeDir.absolutePath
                
                env["PYTHONPATH"] = "${stdlibZip.absolutePath}:${modulesDir.absolutePath}"
                env["PYTHONHOME"] = filesDir.absolutePath
                env["TMPDIR"] = cacheDir.absolutePath
                env["HOME"] = filesDir.absolutePath
                
                processBuilder.directory(filesDir)

                Log.i(TAG, "Starting Python Process...")
                val process = processBuilder.start()

                thread { BufferedReader(InputStreamReader(process.inputStream)).useLines { lines -> lines.forEach { Log.i(TAG, it) } } }
                thread { BufferedReader(InputStreamReader(process.errorStream)).useLines { lines -> lines.forEach { Log.e(TAG, "STDERR: $it") } } }
                
                val exitCode = process.waitFor()
                Log.i(TAG, "Python process exited with code $exitCode")

                if (exitCode != 0) {
                    Log.e(TAG, ">>> TEST_FAILED_MARKER: Process terminated with error ($exitCode) <<<")
                }

            } catch (e: Exception) {
                Log.e(TAG, ">>> TEST_FAILED_MARKER: Kotlin wrapper error: ${e.stackTraceToString()} <<<")
            }
        }
    }

    private fun copyAsset(filename: String, dest: File) {
        if (!dest.exists()) {
            assets.open(filename).use { inputStream ->
                FileOutputStream(dest).use { outputStream ->
                    inputStream.copyTo(outputStream)
                }
            }
        }
    }

    private fun extractZipFromAssets(assetName: String, destDir: File) {
        destDir.mkdirs()
        try {
            assets.open(assetName).use { inputStream ->
                ZipInputStream(inputStream).use { zis ->
                    var entry = zis.nextEntry
                    while (entry != null) {
                        val file = File(destDir, entry.name)
                        if (entry.isDirectory) {
                            file.mkdirs()
                        } else {
                            file.parentFile?.mkdirs()
                            FileOutputStream(file).use { out -> zis.copyTo(out) }
                        }
                        entry = zis.nextEntry
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Asset $assetName not found or could not be extracted.")
        }
    }
}