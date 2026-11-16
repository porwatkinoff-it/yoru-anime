; Обновление из приложения запускает установщик с «/S --force-run» (как у Electron-версии 2.0.x):
; после тихой установки сразу открываем новую версию.
!macro NSIS_HOOK_POSTINSTALL
  ClearErrors
  ${GetOptions} $CMDLINE "--force-run" $0
  ${IfNot} ${Errors}
    Exec '"$INSTDIR\${MAINBINARYNAME}.exe"'
  ${EndIf}
!macroend

; До 2.2 приложение называлось «Yoru Anime» и стояло в своей папке: убираем ту установку, чтобы не было
; двух приложений и ярлыков. Данные (вход, прогресс, загрузки) лежат отдельно и остаются.
!macro NSIS_HOOK_PREINSTALL
  ${If} ${FileExists} "$LOCALAPPDATA\Yoru Anime\uninstall.exe"
    ExecWait '"$LOCALAPPDATA\Yoru Anime\uninstall.exe" /S _?=$LOCALAPPDATA\Yoru Anime'
    Delete "$LOCALAPPDATA\Yoru Anime\uninstall.exe"
    RMDir "$LOCALAPPDATA\Yoru Anime"
  ${EndIf}
!macroend
