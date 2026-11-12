import os


def patch_android_gradle() -> None:
    kts = "android/app/build.gradle.kts"
    groovy = "android/app/build.gradle"
    has_key = os.path.exists("android/key.properties")

    if os.path.exists(kts):
        with open(kts, "r", encoding="utf-8") as f:
            s = f.read()
        s = s.replace("minSdk = flutter.minSdkVersion", "minSdk = 24")
        s = s.replace("targetSdk = flutter.targetSdkVersion", "targetSdk = 35")
        if has_key and 'create("release")' not in s:
            header = (
                'import java.util.Properties\n'
                'import java.io.FileInputStream\n\n'
                'val keystoreProperties = Properties()\n'
                'val keystorePropertiesFile = rootProject.file("key.properties")\n'
                'if (keystorePropertiesFile.exists()) {\n'
                '    keystoreProperties.load(FileInputStream(keystorePropertiesFile))\n'
                '}\n\n'
            )
            s = header + s
            signing_block = (
                '    signingConfigs {\n'
                '        create("release") {\n'
                '            keyAlias = keystoreProperties.getProperty("keyAlias")\n'
                '            keyPassword = keystoreProperties.getProperty("keyPassword")\n'
                '            storeFile = file(keystoreProperties.getProperty("storeFile"))\n'
                '            storePassword = keystoreProperties.getProperty("storePassword")\n'
                '        }\n'
                '    }\n'
                '    buildTypes {'
            )
            s = s.replace("    buildTypes {", signing_block, 1)
            s = s.replace(
                'signingConfig = signingConfigs.getByName("debug")',
                'signingConfig = signingConfigs.getByName("release")',
            )
        with open(kts, "w", encoding="utf-8") as f:
            f.write(s)
        print("Patched build.gradle.kts successfully (has_key=%s)" % has_key)

    elif os.path.exists(groovy):
        with open(groovy, "r", encoding="utf-8") as f:
            s = f.read()
        s = s.replace("minSdkVersion flutter.minSdkVersion", "minSdkVersion 24")
        s = s.replace("targetSdkVersion flutter.targetSdkVersion", "targetSdkVersion 35")
        if has_key and "signingConfigs {" not in s:
            header = (
                'def keystoreProperties = new Properties()\n'
                'def keystorePropertiesFile = rootProject.file("key.properties")\n'
                'if (keystorePropertiesFile.exists()) {\n'
                '    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))\n'
                '}\n\n'
            )
            s = header + s
            signing_block = (
                '    signingConfigs {\n'
                '        release {\n'
                '            keyAlias keystoreProperties["keyAlias"]\n'
                '            keyPassword keystoreProperties["keyPassword"]\n'
                '            storeFile file(keystoreProperties["storeFile"])\n'
                '            storePassword keystoreProperties["storePassword"]\n'
                '        }\n'
                '    }\n'
                '    buildTypes {'
            )
            s = s.replace("    buildTypes {", signing_block, 1)
            s = s.replace(
                "signingConfig signingConfigs.debug",
                "signingConfig signingConfigs.release",
            )
        with open(groovy, "w", encoding="utf-8") as f:
            f.write(s)
        print("Patched build.gradle successfully (has_key=%s)" % has_key)


if __name__ == "__main__":
    patch_android_gradle()
