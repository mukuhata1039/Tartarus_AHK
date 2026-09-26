Option Explicit

Dim shell, fso, root, runtime
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
runtime = root & "\Tartarus_Runtime.vbs"

shell.Run "wscript.exe """ & runtime & """ start", 0, False
WScript.Sleep 450
shell.Run "http://127.0.0.1:8765/", 1, False
