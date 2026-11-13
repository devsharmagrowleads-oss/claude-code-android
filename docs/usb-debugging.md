# Switching on USB debugging

USB debugging lets a laptop you approve send commands to the phone over the cable. The installer needs it. You can switch it off again afterwards.

## Every phone

1. Open **Settings > About phone** (on some phones: About device, or About phone > Software information).
2. Tap **Build number** seven times. Enter your PIN if asked. The phone says "You are now a developer".
3. Go back to Settings and open **Developer options** (often under System, or Additional settings).
4. Switch on **USB debugging** and confirm.
5. Plug the phone into the laptop. When the phone asks **Allow USB debugging?**, tick "Always allow from this computer" and tap **Allow**.

If the laptop still does not see the phone, pull down the phone's notifications, tap the USB notification and choose **File transfer**.

## Extra steps by brand

Menu names change between models and versions. If a name here does not match your phone, search Settings for the words in quotes.

### Samsung

- If USB debugging is greyed out or the install is blocked, switch off **Auto Blocker**: Settings > Security and privacy > Auto Blocker. You can switch it back on afterwards.
- "Build number" is under Settings > About phone > Software information.

### Xiaomi, Redmi, POCO

- Tap **MIUI version** (or **OS version**) seven times instead of Build number.
- Developer options is under Settings > Additional settings.
- Switch on all three: **USB debugging**, **Install via USB**, and **USB debugging (Security settings)**.
- The last two may ask you to sign in to a Mi account and may need a SIM card in the phone.
- During the install, the phone shows a prompt with a countdown. Tap **Install** before it runs out.

### OnePlus, Oppo, Realme

- Developer options is under Settings > System settings (or Additional settings).
- If the installer says it could not change the background-process setting, switch on **Disable permission monitoring** in Developer options and run the installer again.
- The phone may ask you to confirm installing an app over USB. Tap **Install**.

### Vivo, iQOO

- "Build number" is under Settings > About phone > Software information, or Settings > System management > About phone.
- The phone may ask you to confirm installing an app over USB.

### Google Pixel, Motorola, Nokia

- No extra steps. Developer options is under Settings > System.

### Huawei, Honor

- In Developer options, also switch on **Allow ADB debugging in charge only mode**.

## Windows USB drivers

Most phones work on Windows 10 and 11 without extra software. If the phone never shows up, install the maker's USB driver from Google's list:
<https://developer.android.com/studio/run/oem-usb>

## When you are done

Claude Code keeps working with USB debugging off. To switch it off: Settings > Developer options > USB debugging. To make the phone forget the laptop as well, tap **Revoke USB debugging authorisations** in the same menu.
