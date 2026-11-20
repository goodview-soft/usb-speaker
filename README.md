# USB Speaker

Utilise ton téléphone Android comme **enceinte** et **micro** de ton PC Linux, par le câble USB (Godot 4.7).

## Télécharger l'app Android

[usb-speaker.apk](https://github.com/goodview-soft/usb-speaker/releases/latest/download/usb-speaker.apk)

<img src="qr_apk.png" width="220" alt="QR code APK">

## Utilisation
1. Téléphone : active le **Débogage USB** (Options développeur) et branche le câble (mode « Transfert de fichiers »).
2. PC : télécharge [UsbSpeaker-linux.zip](https://github.com/goodview-soft/usb-speaker/releases/latest/download/UsbSpeaker-linux.zip), décompresse, lance `UsbSpeaker.x86_64` (il faut `adb`, `pactl`, `parec`, `pacat`).
3. L'app PC installe/ouvre l'app sur le téléphone et s'y connecte. Une sortie « Telephone-USB » et un micro « Micro-Telephone » apparaissent sur le PC.

Sans `adb` dans le PATH : mettre le binaire `adb` à côté de `UsbSpeaker.x86_64` ou définir `USBSPK_ADB`.
