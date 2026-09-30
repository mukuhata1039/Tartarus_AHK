Option Explicit

Dim shell, fso, root, ps1, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = root & "\Tartarus_Autostart.ps1"

If Not fso.FileExists(ps1) Then
    WScript.Quit 2
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & ps1 & """"

shell.Run cmd, 0, False
