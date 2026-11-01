# Windows x64 build

This fork builds the Windows application on GitHub Actions using
`.github/workflows/build-windows.yaml`. Each push to `feature/happ-subscription`
starts a build on `windows-2022`. The workflow also supports `workflow_dispatch`;
GitHub exposes manual dispatch once the workflow is present on the default branch.

The build uses Flutter 3.41.7, Go 1.26.0 and the runner's Rust/MSVC toolchain and
Inno Setup 6 compiler. It calls `dart setup.dart windows --arch amd64 --env stable`,
which compiles the pinned mihomo core with the REALITY version patch, the Windows
helper service, the Flutter app, a portable ZIP and an EXE installer.

## Constraints

- Target: Windows x64 (Intel/AMD), not Windows ARM64 or 32-bit Windows.
- Preserve Happ/Xray JSON subscription conversion and the REALITY patch.
- Build from committed sources; local macOS settings and personal subscription
  URLs are not build inputs.
- Use the dependencies pinned by `core/go.mod` and `services/helper/Cargo.lock`.
  Keep the original Go module cache unchanged; patch a writable copy using Dart
  file APIs and a separate, quoted Go module replacement path.
- The job needs only repository read permission and no signing secrets.
- Save build artifacts for 30 days. This workflow does not publish releases.

## Download

Open the successful **Build Windows** run in
<https://github.com/stoff7/FlClashX/actions>, then download
**FlClashX-windows-x64** from **Artifacts**. It contains:

- `FlClashX-windows-amd64-setup.exe`: installer.
- `FlClashX-windows-amd64.zip`: portable application; extract the whole ZIP and
  run `FlClashX.exe` with its accompanying files present.
- SHA-256 files and `BUILD.txt` identifying the source commit.

The packages are unsigned. Installation requires administrator access for the
Windows helper service.

## Acceptance checks

CI must pass `flutter test test/xray_test.dart`, compile the patched core and
helper, compile the Windows application and create both packages with checksums.

On a Windows computer, install the EXE, launch the app, import a Happ subscription
and check connectivity in both system proxy and TUN modes. These interactive
checks must be recorded separately; compilation on a runner cannot establish
that the user's VPN subscription or network works.
