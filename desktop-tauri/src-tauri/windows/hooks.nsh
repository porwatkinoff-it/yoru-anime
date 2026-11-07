; Обновление из приложения запускает установщик с «/S --force-run» (как у Electron-версии 2.0.x):
; после тихой установки сразу открываем новую версию.
!macro NSIS_HOOK_POSTINSTALL
  ClearErrors
  ${GetOptions} $CMDLINE "--force-run" $0
  ${IfNot} ${Errors}
    Exec '"$INSTDIR\${MAINBINARYNAME}.exe"'
  ${EndIf}
!macroend
