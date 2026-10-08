ZARP — first launch / первый запуск
==================================

Requires an Apple Silicon Mac (M1 or newer). Tested on macOS 15; macOS 14 should work but has not
been tested.  Нужен Mac с процессором Apple Silicon (M1 и новее). Проверено на macOS 15; macOS 14
должна работать, но не проверялась.


English
-------
1. Drag Zarp into the Applications folder (the shortcut next to it), then eject this disk image.
   Do not run Zarp from the disk image or from Downloads.

2. Open Zarp from Applications. The first time, macOS refuses to open it because it cannot verify
   the developer. That is expected: this build is not notarized by Apple (it is not signed with a
   paid Apple Developer ID).

3. Open System Settings > Privacy & Security and scroll down to the Security section. It now says
   "Zarp" was blocked to protect your Mac: click "Open Anyway", confirm with your password or Touch
   ID, then click Open. (On macOS 15 the older Control-click > Open shortcut no longer works.)

4. In Zarp, click the gear icon, find the "zarpd daemon" section and click Install (this only works
   when Zarp is in the Applications folder). macOS shows a
   "background items added" notification: open System Settings > General > Login Items &
   Extensions and switch Zarp on under "Allow in the Background" (password or Touch ID). This is
   needed only once.

5. Turn off any other VPN (Zarp refuses to build a tunnel on top of one), then press the big power
   button. The first time, Zarp asks to create a free anonymous Cloudflare WARP account for this Mac
   and to accept Cloudflare's terms for you. It then finds a strategy that works on your network and
   connects: while it says "Connected", ALL of this Mac's traffic (and DNS) goes through WARP.
   Settings has switches for that ("Route all traffic through WARP", "Use Cloudflare DNS"); if the
   connection ever drops, Zarp reconnects by itself.

If step 3 does not offer "Open Anyway", this Terminal command removes the block instead:
    xattr -dr com.apple.quarantine /Applications/Zarp.app

Something went wrong?  https://github.com/feg55/Zarp-MacOS/blob/main/docs/TROUBLESHOOTING.md
Zarp is free software under the MIT License (LICENSE.txt, next to this file).


Русский
-------
1. Перетащите Zarp в папку «Программы» (ярлык рядом), затем извлеките этот образ диска.
   Не запускайте Zarp прямо из образа диска или из «Загрузок».

2. Откройте Zarp из «Программ». При первом запуске macOS откажется его открыть, потому что не может
   проверить разработчика. Так и должно быть: эта сборка не нотаризована Apple (она не подписана
   платным сертификатом Apple Developer ID).

3. Откройте «Системные настройки» > «Конфиденциальность и безопасность» и прокрутите вниз до раздела
   «Безопасность». Там будет сообщение, что файл «Zarp» заблокирован для защиты вашего Mac: нажмите
   «Все равно открыть», подтвердите паролем или Touch ID, затем нажмите «Открыть». (В macOS 15
   прежний способ — Control-клик > «Открыть» — больше не работает.)

4. В Zarp нажмите значок шестерёнки, найдите раздел «Служба zarpd» и нажмите «Установить» (это
   работает, только если Zarp лежит в папке «Программы»). macOS покажет
   уведомление о добавлении фоновых объектов: откройте «Системные настройки» > «Основные» >
   «Объекты входа и расширения» и включите Zarp в разделе «Разрешить в фоновом режиме» (пароль или
   Touch ID). Это нужно сделать только один раз.

5. Выключите другой VPN (поверх него Zarp туннель не строит), затем нажмите большую кнопку питания.
   В первый раз Zarp предложит создать бесплатный анонимный аккаунт Cloudflare WARP для этого Mac и от
   вашего имени принять условия Cloudflare. Затем он сам подберёт стратегию, которая работает в вашей
   сети, и подключится: пока написано «Подключено», ВЕСЬ трафик этого Mac (и DNS) идёт через WARP.
   В настройках есть переключатели («Пускать весь трафик через WARP», «Использовать DNS Cloudflare»);
   если соединение оборвётся, Zarp переподключится сам.

Если на шаге 3 нет кнопки «Все равно открыть», снять блокировку можно командой в Терминале:
    xattr -dr com.apple.quarantine /Applications/Zarp.app

Что-то пошло не так?  https://github.com/feg55/Zarp-MacOS/blob/main/docs/TROUBLESHOOTING.md (на английском)
Zarp — свободное ПО по лицензии MIT (LICENSE.txt рядом с этим файлом).
