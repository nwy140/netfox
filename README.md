# MuJoCo Drop Lab

Drop three free bodies into a MuJoCo world and inspect the results in Godot. Right-drag to orbit and scroll to zoom. **Pause** freezes the model, **Step** advances one Godot physics tick and pauses, and **Reset** restores the original poses and clock.

## Local tools

The workspace uses Godot 4.7.2 standard, Visual Studio 2022 with the Windows x64 C++ toolchain, CMake 3.24 or newer, Git, Python for godot-cpp binding generation, and Node.js 18 or newer for Godot MCP. The project and exported game run MuJoCo 3.12.0 in-process. They need neither Python nor a server at runtime.

The root game and nested `godot-mujoco/` are independent Git repositories. The fork tracks `origin/main` at yunerious and has gstohl as `upstream`. This workspace uses fork commit `8bd65af` for the Windows DirAccess compatibility fix. It is a local commit. Preserve it when moving the setup by transferring that commit with Git.

## Build and run

Run these commands in the project directory. The first build downloads pinned MuJoCo and godot-cpp. Subsequent builds reuse the CMake trees. The script stages both debug and release DLLs and the MuJoCo runtime in the root addon. The Godot editor imports only the root game because the nested fork has a local `.gdignore`.

```powershell
./tools/build-windows.ps1
$godot = (Resolve-Path ../../GodotApp/Godot_v4.7.2-stable_win64_console.exe).Path
& $godot --path . --editor
```

Press F6 with `lab/Lab.tscn` open or F5 to run the main scene. Use `code .` for script and native editing. Close running instances before rebuilding DLLs that Windows has locked.

## Verify and export

Install the Windows x86-64 templates from the official 4.7.2 standard template archive if moving to another computer. The debug and release templates are installed on this machine.

```powershell
& $godot --headless --path . --editor --import
& $godot --headless --path . --quit-after 180 -- --smoke
New-Item -Force -ItemType Directory dist | Out-Null
& $godot --headless --path . --export-release 'Windows x86_64' dist/DropLab.exe
Copy-Item addons/godot_mujoco/*.txt dist/
Push-Location dist
$run = Start-Process ./DropLab.exe -ArgumentList '--headless --quit-after 180 --log-file export-smoke.log -- --smoke' -Wait -PassThru -WindowStyle Hidden
Get-Content export-smoke.log
$run.ExitCode
Pop-Location
```

Expect exit code zero and `DROP LAB PASS`. The test checks time stepping, pause, floor contact, visual pose synchronization and reset. The Windows export embeds the Godot resource pack in `DropLab.exe`. Keep its two adjacent DLLs and license notices when copying it to another folder.

## Develop

- `lab/drop_lab.xml` defines the physical bodies and collision geometry. MJCF uses Z-up and box half-extents. Godot uses Y-up and full mesh dimensions.
- `lab/lab.gd` creates the camera, lighting, visuals and controls. It calls `MjWorld.step(4)` per 60 Hz tick and maps each body transform from MuJoCo into Godot coordinates. Add new named bodies to the MJCF and bind Godot visuals by name.
- For robots, inspect joint, actuator and sensor names and dimensions before wiring controls. Place each MJCF model and its relative assets in a dedicated directory, include those raw files in the export preset, and test the packed export. Keep RL or ONNX inference behind an explicit controller interface. Use a single authoritative simulator when adding multiplayer.
- The native API and upstream example tests live in the fork. See its README for model loading, state, controls, sensors and visual debugging.
- The Coding-Solo Godot MCP server is installed at `../../Tools/godot-mcp` and registered as `godot` in Codex. Its stdio protocol was tested with version and project queries, editor launch, project run, debug output and stop. A fresh Codex invocation connected and discovered its tools. This session's approval policy blocked the actual Codex tool calls. Use the terminal for deterministic builds, exports and exit-code checks.
- The installed Codex skill is `godot-mujoco-development`. Start a new Codex chat if the skill or newly registered server is missing from the current chat.

Sources: [Godot release and templates](https://github.com/godotengine/godot-builds/releases/tag/4.7.2-stable), [MuJoCo integration](https://github.com/gstohl/godot-mujoco), [Godot MCP](https://github.com/Coding-Solo/godot-mcp).
