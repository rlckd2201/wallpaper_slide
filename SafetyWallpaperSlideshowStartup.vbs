Option Explicit

Dim shell
Dim fileSystem
Dim programDataPath
Dim launcherPath

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

programDataPath = shell.ExpandEnvironmentStrings("%ProgramData%")
launcherPath = fileSystem.BuildPath(programDataPath, "SafetyWallpaper\RunSafetyWallpaperSlideshowHidden.vbs")

If fileSystem.FileExists(launcherPath) Then
    shell.Run "wscript.exe //B //Nologo " & Chr(34) & launcherPath & Chr(34), 0, False
End If
