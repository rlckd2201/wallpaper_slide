Option Explicit

Dim shell
Dim fileSystem
Dim root
Dim scriptPath
Dim trayPath
Dim command
Dim trayCommand

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

root = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(root, "SafetyWallpaperSlideshow.ps1")
trayPath = fileSystem.BuildPath(root, "SafetyWallpaperTray.ps1")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)
trayCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & trayPath & Chr(34)

shell.CurrentDirectory = root
shell.Run command, 0, False
shell.Run trayCommand, 0, False
