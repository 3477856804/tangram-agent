#!/usr/bin/env python3
# 版本递增：0.0.0 →(bump)→ 0.0.1 → … → 0.0.99 → 0.1.0；--retry 只加 build 位。
# 单一真源 frontend/android/version.properties，gradle 与 CI 都从这里读。
import sys
from pathlib import Path

VERSION_FILE = Path(__file__).resolve().parent.parent / "version.properties"


def load():
    props = {}
    for line in VERSION_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        k, v = line.split("=", 1)
        props[k.strip()] = v.strip()
    return (
        int(props.get("major", "0")),
        int(props.get("minor", "0")),
        int(props.get("patch", "0")),
        int(props.get("build", "0")),
    )


def save(major, minor, patch, build):
    VERSION_FILE.write_text(
        f"major={major}\nminor={minor}\npatch={patch}\nbuild={build}\n",
        encoding="utf-8",
    )


def version_name(major, minor, patch):
    if patch == 0:
        return f"{major}.{minor}.0"
    if minor == 0:
        return f"{major}.{minor}.{patch}"
    return f"{major}.{minor}.{patch:02d}"


def version_code(major, minor, patch, build):
    if not (0 <= minor <= 99 and 0 <= patch <= 99 and 0 <= build <= 999):
        raise SystemExit("minor/patch 必须在 0-99，build 必须在 0-999")
    return major * 10_000_000 + minor * 100_000 + patch * 1_000 + build


def main():
    major, minor, patch, build = load()

    if "--retry" in sys.argv[1:]:
        build += 1
        if build > 999:
            raise SystemExit("build 超过 999，请改用正式 bump")
    else:
        build = 0
        if patch == 99:
            minor += 1
            patch = 0
            if minor > 99:
                major += 1
                minor = 0
        else:
            patch += 1

    save(major, minor, patch, build)
    print(f"versionName={version_name(major, minor, patch)}")
    print(f"versionCode={version_code(major, minor, patch, build)}")


if __name__ == "__main__":
    main()
