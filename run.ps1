# Start Genie Buddy. Agents reach it on http://127.0.0.1:8777
# Godot 4.7+ is found via $env:GODOT, else the first godot*.exe on PATH.
$godot = $env:GODOT
if (-not $godot) {
    $godot = (Get-Command 'godot*' -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch 'console' } | Select-Object -First 1).Source
}
if (-not $godot) { throw 'Godot not found: set $env:GODOT to the Godot 4.7+ executable.' }
Start-Process -FilePath $godot -ArgumentList '--path', "`"$PSScriptRoot\godot`""
