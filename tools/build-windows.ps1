$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$source = Join-Path $project 'godot-mujoco'
$bin = Join-Path $project 'addons/godot_mujoco/bin'
$profile = Join-Path $PSScriptRoot 'godot-cpp-profile.json'

if (!(Test-Path (Join-Path $source 'CMakeLists.txt'))) {
    throw 'Clone the MuJoCo fork into the godot-mujoco subdirectory first.'
}
$ignore = Join-Path $source '.gdignore'
if (!(Test-Path $ignore)) {
    New-Item -ItemType File $ignore | Out-Null
}
New-Item -Force -ItemType Directory $bin | Out-Null

foreach ($variant in @('template_debug', 'template_release')) {
    $build = Join-Path $source $(if ($variant -eq 'template_debug') { 'build' } else { 'build-release' })
    cmake -S $source -B $build -G 'Visual Studio 17 2022' -A x64 `
        "-DGODOTCPP_TARGET=$variant" "-DGODOTCPP_BUILD_PROFILE=$profile" "-DGMJ_ADDON_BIN=$bin"
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed for $variant" }
    cmake --build $build --config Release --parallel 4
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed for $variant" }
    # Restage even if MSBuild reports that all targets are already up to date.
    Copy-Item (Join-Path $build "Release/libgodot_mujoco.windows.$variant.x86_64.dll") $bin
}
Copy-Item (Join-Path $source 'build/_deps/mujoco-src/bin/mujoco.dll') $bin
