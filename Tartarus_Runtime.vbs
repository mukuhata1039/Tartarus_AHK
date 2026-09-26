Option Explicit

Dim shell, fso, root, ps1, action, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = root & "\Tartarus_Runtime.ps1"
action = "start"

If WScript.Arguments.Count > 0 Then
    action = LCase(WScript.Arguments(0))
End If

If Not fso.FileExists(ps1) Then
    WScript.Quit 2
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & ps1 & """ " & action

shell.Run cmd, 0, False
