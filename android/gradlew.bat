@echo off
setlocal
set JAVA_EXE=%JAVA_HOME%\bin\java.exe
if not defined JAVA_HOME goto noJavaHome
if not exist "%JAVA_EXE%" goto noJavaHome
set DIRNAME=%~dp0
"%JAVA_EXE%" -classpath "%DIRNAME%gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain %*
exit /b 0
:noJavaHome
if exist "%JAVA_HOME%\jre\bin\java.exe" set JAVA_EXE=%JAVA_HOME%\jre\bin\java.exe
if not defined JAVA_EXE goto fail
"%JAVA_EXE%" -classpath "%DIRNAME%gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain %*
exit /b 0
:fail
echo ERROR: JAVA_HOME is not set and no java found in PATH.
exit /b 1
