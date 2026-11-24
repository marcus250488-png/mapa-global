#!/usr/bin/env python3
"""Ajusta o projeto Android gerado pelo `flutter create` (roda no GitHub Actions)."""
import pathlib
import re
import sys

APP_NAME = "Monitor Global"

android = pathlib.Path("android")
if not android.is_dir():
    sys.exit("pasta android não encontrada")

# 1) Manifesto: permissão de internet (o release não a traz) e nome do app.
manifest = android / "app/src/main/AndroidManifest.xml"
m = manifest.read_text(encoding="utf-8")
if "android.permission.INTERNET" not in m:
    m = m.replace(
        "<application",
        '<uses-permission android:name="android.permission.INTERNET"/>\n    <application',
        1,
    )
m = re.sub(r'android:label="[^"]*"', f'android:label="{APP_NAME}"', m, count=1)
manifest.write_text(m, encoding="utf-8")

# 2) Ícone pequeno das notificações (só o canal alfa conta). Círculo com exclamação.
drawable = android / "app/src/main/res/drawable"
drawable.mkdir(parents=True, exist_ok=True)
(drawable / "ic_stat_notify.xml").write_text(
    """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:fillType="evenOdd"
        android:pathData="M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM13,17h-2v-2h2v2zM13,13h-2V7h2v6z"/>
</vector>
""",
    encoding="utf-8",
)

# 3) Gradle: desugaring (exigido pelo flutter_local_notifications) e compileSdk mínimo.
kts = android / "app/build.gradle.kts"
groovy = android / "app/build.gradle"
if kts.exists():
    g = kts.read_text(encoding="utf-8")
    if "isCoreLibraryDesugaringEnabled" not in g:
        g, n = re.subn(
            r"compileOptions\s*\{",
            "compileOptions {\n        isCoreLibraryDesugaringEnabled = true",
            g,
            count=1,
        )
        if n != 1:
            sys.exit("bloco compileOptions não encontrado em build.gradle.kts")
        g += (
            "\ndependencies {\n"
            '    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n'
            "}\n"
        )
    g = g.replace(
        "compileSdk = flutter.compileSdkVersion",
        "compileSdk = maxOf(flutter.compileSdkVersion, 36)",
    )
    kts.write_text(g, encoding="utf-8")
elif groovy.exists():
    g = groovy.read_text(encoding="utf-8")
    if "coreLibraryDesugaringEnabled" not in g:
        g, n = re.subn(
            r"compileOptions\s*\{",
            "compileOptions {\n        coreLibraryDesugaringEnabled true",
            g,
            count=1,
        )
        if n != 1:
            sys.exit("bloco compileOptions não encontrado em build.gradle")
        g += (
            "\ndependencies {\n"
            "    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n"
            "}\n"
        )
    groovy.write_text(g, encoding="utf-8")
else:
    sys.exit("build.gradle(.kts) do app não encontrado")

print("Projeto Android ajustado.")
