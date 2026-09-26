@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================
rem  Tartarus AHK - Commit + Push
rem  Target: E:\app\Tartarus_AHK_v9_PORTABLE
rem ============================================================

set "REPO=E:\app\Tartarus_AHK_v9_PORTABLE"

cls
echo.
echo ============================================================
echo  Tartarus AHK - Commit + Push
echo ============================================================
echo Repository:
echo %REPO%
echo.

rem ------------------------------------------------------------
rem Basic checks
rem ------------------------------------------------------------
where git.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: git.exe was not found in PATH.
    echo Install Git for Windows or fix PATH first.
    pause
    exit /b 1
)

if not exist "%REPO%\" (
    echo ERROR: Repository folder was not found.
    echo %REPO%
    pause
    exit /b 1
)

cd /d "%REPO%"
if errorlevel 1 (
    echo ERROR: Failed to open repository folder.
    pause
    exit /b 1
)

rem ------------------------------------------------------------
rem First-run Git setup
rem ------------------------------------------------------------
if not exist ".git\" (
    echo Git repository is not initialized.
    echo Initializing now...
    echo.

    git init
    if errorlevel 1 goto :git_error

    git branch -M main
    if errorlevel 1 goto :git_error
)

rem ------------------------------------------------------------
rem Keep runtime junk / huge logs out of Git.
rem Existing .gitignore content is preserved.
rem ------------------------------------------------------------
call :EnsureIgnore "# Tartarus local/runtime files"
call :EnsureIgnore "__pycache__/"
call :EnsureIgnore "*.pyc"
call :EnsureIgnore "*.pyo"
call :EnsureIgnore "Logs/"
call :EnsureIgnore "*.log"
call :EnsureIgnore "*.pcap"
call :EnsureIgnore "*.pcapng"
call :EnsureIgnore "Tartarus_CurrentMap.txt"
call :EnsureIgnore "Tartarus_LED_State.txt"
call :EnsureIgnore "STARTUP_ERROR.txt"

rem If an ignored file was tracked in an older commit, untrack it now.
for /f "usebackq delims=" %%F in (`git ls-files -ci --exclude-standard 2^>nul`) do (
    echo Untracking ignored file: %%F
    git rm --cached -- "%%F" >nul 2>nul
)

rem ------------------------------------------------------------
rem Configure origin only when needed.
rem Future runs reuse the saved origin automatically.
rem ------------------------------------------------------------
git remote get-url origin >nul 2>nul
if errorlevel 1 (
    echo.
    echo No GitHub remote is configured yet.
    echo Example: https://github.com/mukuhata1039/Tartarus_AHK.git
    set "REMOTE="
    set /p "REMOTE=GitHub repository URL: "

    if not defined REMOTE (
        echo ERROR: Repository URL cannot be empty.
        pause
        exit /b 1
    )

    git remote add origin "!REMOTE!"
    if errorlevel 1 (
        echo ERROR: Failed to add origin.
        pause
        exit /b 1
    )
) else (
    for /f "delims=" %%R in ('git remote get-url origin') do set "CURRENT_REMOTE=%%R"
    echo GitHub remote:
    echo !CURRENT_REMOTE!
)

rem ------------------------------------------------------------
rem Detect current branch
rem ------------------------------------------------------------
set "BRANCH="
for /f "delims=" %%B in ('git branch --show-current') do set "BRANCH=%%B"
if not defined BRANCH (
    set "BRANCH=main"
    git branch -M main >nul 2>nul
)

echo.
echo Current branch: !BRANCH!
echo.

rem ------------------------------------------------------------
rem Show changes
rem ------------------------------------------------------------
echo Current changes:
echo ------------------------------------------------------------
git status --short
echo ------------------------------------------------------------
echo.

set "STATUS_FILE=%TEMP%\tartarus_git_status_%RANDOM%_%RANDOM%.txt"
git status --porcelain > "%STATUS_FILE%"
for %%A in ("%STATUS_FILE%") do set "STATUS_SIZE=%%~zA"
del "%STATUS_FILE%" >nul 2>nul

rem ------------------------------------------------------------
rem Commit only when there are local file changes
rem ------------------------------------------------------------
if not "!STATUS_SIZE!"=="0" (
    set "MSG="
    set /p "MSG=Commit message: "

    if not defined MSG (
        echo ERROR: Commit message cannot be empty.
        pause
        exit /b 1
    )

    echo.
    echo Staging all changes...
    git add -A
    if errorlevel 1 goto :git_error

    rem Safety check: block files that GitHub would reject anyway.
    set "LARGE_FILE_FOUND=0"
    for /f "usebackq delims=" %%F in (`git diff --cached --name-only --diff-filter=ACMRT 2^>nul`) do (
        if exist "%%F" (
            for %%S in ("%%F") do (
                if %%~zS GTR 95000000 (
                    echo.
                    echo ERROR: Staged file is larger than 95 MB:
                    echo   %%F
                    echo   Size: %%~zS bytes
                    set "LARGE_FILE_FOUND=1"
                )
            )
        )
    )
    if "!LARGE_FILE_FOUND!"=="1" (
        echo.
        echo Remove the large file or add it to .gitignore, then run this BAT again.
        git reset >nul 2>nul
        pause
        exit /b 1
    )

    echo.
    echo Committing...
    git commit -m "!MSG!"
    if errorlevel 1 goto :git_error
) else (
    echo No file changes to commit.
    echo Checking for unpushed commits...
)

rem ------------------------------------------------------------
rem Push. First push automatically sets upstream.
rem ------------------------------------------------------------
echo.
echo Pushing...
git push
if errorlevel 1 (
    echo.
    echo Normal push failed. Trying to set upstream...
    git push -u origin "!BRANCH!"
    if errorlevel 1 (
        echo.
        echo ERROR: git push failed.
        echo Local commits are still safe on this PC.
        echo.
        echo If GitHub already contains an initial README/license commit,
        echo the remote history may need to be reconciled once before pushing.
        pause
        exit /b 1
    )
)

echo.
echo ============================================================
echo  DONE
echo ============================================================
git log -1 --oneline
echo.
pause
exit /b 0

rem ------------------------------------------------------------
rem Append one exact line to .gitignore only when absent.
rem ------------------------------------------------------------
:EnsureIgnore
set "IGNORE_LINE=%~1"
if not exist ".gitignore" type nul > ".gitignore"
findstr /x /l /c:"%IGNORE_LINE%" ".gitignore" >nul 2>nul
if errorlevel 1 echo %IGNORE_LINE%>> ".gitignore"
exit /b 0

:git_error
echo.
echo ERROR: A Git command failed.
echo Local files have not been deleted.
echo.
pause
exit /b 1
