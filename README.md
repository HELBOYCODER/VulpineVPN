<div align="center">

# Vulpine VPN for macOS & Windows 🦊

**Unofficial Firefox VPN client for macOS and Windows** — a desktop port of
[Vauth/FoxyVPN](https://github.com/Vauth/FoxyVPN) built with Kotlin and
Compose Multiplatform, keeping the original Material 3 UI pixel-for-pixel.

*کلاینت رسمی‌نبودِ Firefox VPN برای مک — پورت دسکتاپ پروژهٔ FoxyVPN با Kotlin و
Compose Multiplatform و همان رابط Material 3 نسخهٔ اندروید.*

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-000000?style=for-the-badge&logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-x64-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![iPhone](https://img.shields.io/badge/iPhone-share_over_LAN-14213D?style=for-the-badge&logo=apple&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-2.2-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white)
![Compose](https://img.shields.io/badge/Compose%20Multiplatform-1.9-4285F4?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

</div>

---

## English

### What is this?
Vulpine VPN signs in with a **Firefox Account**, obtains a proxy pass from
Mozilla's Guardian service, and carries your traffic through Firefox VPN's
Fastly edge over an HTTP/2 tunnel — the same engine as the Android app
[FoxyVPN](https://github.com/Vauth/FoxyVPN), ported to macOS.

> [!NOTE]
> **No subscription required.** It runs on the free **50 GB/month** of VPN
> traffic Mozilla includes with a Firefox account (the same allowance the
> Firefox browser's built-in VPN uses).

### Features
- Firefox Account sign-in (email + password, Hawk/OAuth — same as Android)
- Server/location picker with latency measurement
- Two traffic modes: **Proxy-only** (local SOCKS5) and **System proxy**
- **Share with a phone** — publish the tunnel as an HTTP proxy on the local
  network so an iPhone/iPad (or any other device) can use this VPN
- Private DNS by default + DNS-over-HTTPS options
- Upstream proxy chaining (chain behind another SOCKS5/HTTP proxy)
- Exit verification, in-app logs, dark/light/system theme
- Split-tunneling list (macOS app picker)
- Native installers with bundled JRE — **no Java installation needed**
  (`.dmg` for macOS, `.exe`/`.msi` for Windows)
- One-time administrator approval for system proxy (survives app restarts
  and upgrades; never asks again)

### Requirements
- macOS 11 or newer, **Apple Silicon** (arm64), **or** Windows 10/11 x64
- A Firefox account — create one free at
  [accounts.firefox.com](https://accounts.firefox.com/signup)

### Installation
1. Download the latest installer from
   [Releases](https://github.com/HELBOYCODER/VulpineVPN/releases):
   `VulpineVPN-x.y.z.dmg` (macOS) or `VulpineVPN-x.y.z.exe` (Windows).
2. **macOS:** open the DMG and drag **Vulpine VPN** to *Applications*.
   **Windows:** run the `.exe` installer (per-user, no admin needed).
3. The build is **not signed with an Apple Developer ID** (local build).
   On first launch, do one of:
   - Right-click the app → **Open** → **Open**, or
   - In Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/VulpineVPN.app
     ```
   - **Windows:** SmartScreen shows *"Windows protected your PC"* for the
     unsigned build — click **More info → Run anyway**.

### How to use
1. Launch **Vulpine VPN** and sign in with your Firefox account.
2. Pick a location (or keep *Recommended Location*).
3. Press the power button.
   - **System proxy** (default): Chrome, Edge, Safari and Firefox traffic
     is routed automatically.
     - **Windows:** two choices in *Settings → Traffic capture*:
     - **System proxy** — per-user registry settings, no admin prompt;
       browsers and WinINet-aware apps go through the VPN.
     - **Full tunnel** — all system traffic (IPv4/IPv6) is captured by a
       virtual adapter (sing-box TUN), like a real VPN client. The first
       connection shows one UAC prompt which registers a scheduled-task
       helper; every later connect is silent. If the app is killed, the
       helper tears the tunnel down automatically within 3 minutes.
     - **macOS:** the very first connection asks for administrator access
       once (a tiny LaunchDaemon helper toggles the proxy). It never asks
       again, even after app updates or reinstalls.
   - **Proxy-only mode** (Settings → Local proxy → Proxy-only mode): no
     system changes; point individual apps at `SOCKS5 127.0.0.1:1080`.
4. Verify: open [ipify.org](https://ipify.org) in the browser — you should
   see the VPN exit IP, not your own.

> [!TIP]
> **Telegram Desktop** ignores the macOS system proxy by design. In
> Telegram: *Settings → Connection → Proxy → Add proxy → SOCKS5,
> `127.0.0.1`, port `1080`* — it works in both modes.

### Use it on an iPhone or iPad
Apple does not let a third-party app create a system-wide tunnel on iOS
without a paid Developer account and a VPN entitlement, so there is no
`.ipa` to sideload. Instead Vulpine shares the tunnel it already holds
with the phone, over the local network:

1. On the Mac: *Settings → Share with a phone* → switch it on. Note the
   address shown (your Mac's Wi-Fi/Ethernet IP and port `1081`).
2. Connect Vulpine as usual, and keep the Mac awake on the same Wi-Fi.
3. On the iPhone: *Settings → Wi‑Fi → (i)* next to that network →
   **HTTP Proxy → Manual**, then Server = the Mac's address,
   Port = `1081`, Authentication off.
4. Browsing in Safari and in apps that honour the Wi‑Fi proxy now leaves
   through the VPN exit. Set the proxy back to **Off** when you disconnect.

The address and the steps can be copied with one click in
*Settings → Share with a phone → Address and steps*, which also exports a
`.mobileconfig` for supervised devices (Apple Configurator / MDM). Apple only
applies that profile when the device is supervised, so on a personal iPhone
step 3 above is the supported path. Both are HTTP-proxy based; only traffic
on the shared Wi-Fi network is carried, and cellular data is untouched.

> [!NOTE]
> macOS may ask once whether to allow incoming connections for the app
> ( firewall prompt ). Choose **Allow**, otherwise the phone cannot reach
> the Mac.

### Data & logs
- Settings and tokens (values AES-256-GCM encrypted):
  `~/Library/Application Support/FoxyVPN/`
- Helper logs: `~/Library/Application Support/FoxyVPN/helper/launchd.*`
- In-app logs: **Settings → Logs** (copy or export to a file)

### Removing the privileged helper
Closing the app **does not** remove it (by design). To remove completely:
```bash
sudo launchctl bootout system/com.vauth.foxyvpn.helper
sudo rm /Library/LaunchDaemons/com.vauth.foxyvpn.helper.plist
```

### Troubleshooting
| Symptom | Fix |
|---|---|
| Browser traffic doesn't change | Make sure *Proxy-only mode* is **off** in Settings, then reconnect; check `scutil --proxy` shows `SOCKSEnable : 1` |
| "System proxy needs administrator access" | The admin prompt was declined — reconnect and approve it once |
| Old icon stuck in Dock | `killall Dock` |
| Quota exhausted | Mozilla's 50 GB resets monthly; try again after reset |
| Another VPN behaves oddly after disconnect | The helper restores the proxy on disconnect; fully quit and relaunch the app if needed |
| iPhone cannot reach the shared proxy | Both devices must be on the same Wi-Fi, the Mac must stay awake and connected, and the macOS firewall must **Allow** incoming connections for the app; `curl -x http://<mac-ip>:1081 https://ipify.org` from another machine proves the path |
| `.mobileconfig` installs but nothing changes on iOS | Apple applies the global HTTP proxy payload only on supervised devices; on a personal iPhone set *Settings → Wi‑Fi → (i) → HTTP Proxy → Manual* instead |

### Building from source
```bash
git clone https://github.com/HELBOYCODER/VulpineVPN.git
cd VulpineVPN-mac
# JDK 17+ and Gradle 8.10 required (no Android SDK needed)
gradle packageDistributionForCurrentOS
# macOS output: build/compose/binaries/main/dmg/*.dmg
# Windows output: build/compose/binaries/main/exe/*.exe (and msi/)
```
Pushing a `v*` tag triggers the **Build installers** GitHub Actions
workflow, which compiles both installers on native runners and attaches
them to the release automatically.
Headless verification harness: `gradle connectTest` (connects with the
stored session, checks the system proxy and exit IP, then restores).

### Architecture (how the port works)
- `src/main/kotlin/compat/` — a minimal Android-compatibility layer
  (`android.content.Context`, `SharedPreferences`, `Toast`, `Base64`,
  `EncryptedSharedPreferences`, `LocalContext`, `PackageManager`, …) so the
  Android UI sources compile **unchanged** on desktop.
- The VPN engine (local SOCKS5 server, Netty HTTP/2 tunnel to the Fastly
  edge, Guardian proxy-pass renewal, edge failover, watchdog) is the
  original JVM code, reused as-is.
- `vpn/http/LocalHttpProxyServer.kt` — an HTTP proxy (CONNECT plus
  absolute-URI forwarding) published on the local network for devices that
  cannot use SOCKS, iPhone first among them. It carries its flows through the
  *same* `UpstreamSession` as the SOCKS5 server, so a phone leaves by the same
  exit as the Mac. `vpn/http/IosProfile.kt` writes the matching
  `.mobileconfig`, and `vpn/http/LanAddress.kt` finds the address a phone can
  actually reach.
- `vpn/tun/MacHelper.kt` — the privileged LaunchDaemon helper that toggles
  the macOS system proxy (admin approval once, then silent).
- The engine itself always bypasses the system proxy it configures
  (`ProxySelector` pinned to DIRECT), so control-plane traffic never loops.
- Full tunnel (TUN) exists on **Windows only** (`vpn/tun/WindowsTun.kt` +
  `WindowsTunConfig.kt`); it was removed from macOS in v1.0.4-mac3 at user
  request. On Windows, bypass host-routes + a fake-DNS bootstrap resolver
  keep the engine's own edge/control-plane sockets out of the tunnel.

---

## فارسی

### این چیست؟
والپاین وی‌پی‌ان با **اکانت فایرفاکس** وارد می‌شود، از سرویس Guardian موزیلا
«proxy pass» می‌گیرد و ترافیک شما را از طریق لبهٔ Fastly و تونل HTTP/2 عبور
می‌دهد — همان موتور نسخهٔ اندروید (FoxyVPN) که برای مک پورت شده است.

> **اشتراک لازم نیست.** روی همان سقف رایگان **۵۰ گیگ در ماه** موزیلا کار
> می‌کند که برای اکانت‌های فایرفاکس (VPN داخلی مرورگر فایرفاکس) در نظر گرفته
> شده و ماهانه ریست می‌شود.

### امکانات
- ورود با اکانت فایرفاکس (ایمیل + رمز)
- انتخاب سرور/کشور با سنجش تأخیر
- دو حالت ترافیک: **فقط پروکسی** (SOCKS5 لوکال) و **پروکسی سیستمی**
- DNS خصوصی به‌صورت پیش‌فرض + گزینه‌های DNS-over-HTTPS
- اتصال زنجیره‌ای به پروکسی بالادستی (SOCKS5/HTTP)
- بررسی IP خروجی، لاگ داخلی، تم تیره/روایت/سیستمی
- خروجی `.app` با JRE داخلی — **نیازی به نصب جاوا نیست**
- یک‌بار اجازهٔ ادمین برای پروکسی سیستمی — با نصب مجدد یا آپدیت هم تکرار
  نمی‌شود

### پیش‌نیازها
- macOS 11 یا جدیدتر (اپل سیلیکون) **یا** ویندوز 10/11 (64-bit)
- اکانت فایرفاکس — ساخت رایگان در
  [accounts.firefox.com](https://accounts.firefox.com/signup)

### نصب
1. از بخش [Releases](https://github.com/HELBOYCODER/VulpineVPN/releases)
   آخرین نصبی را بگیرید: `VulpineVPN-x.y.z.dmg` (مک) یا `VulpineVPN-x.y.z.exe` (ویندوز).
2. **مک:** DMG را باز کنید و **Vulpine VPN** را به *Applications* بکشید.
   **ویندوز:** فایل `.exe` را اجرا کنید (نصب در سطح کاربر، بدون ادمین).
3. بیلد با Developer ID اپل **امضا نشده** (ساخت محلی). بار اول یکی از این دو:
   - راست‌کلیک روی اپ → **Open** → دوباره **Open**، یا
   - در ترمینال:
     ```bash
     xattr -dr com.apple.quarantine /Applications/VulpineVPN.app
     ```
   - **ویندوز:** چون بیلد امضا نشده، SmartScreen پیام *"Windows protected
     your PC"* می‌دهد — روی **More info → Run anyway** کلیک کنید.

### طرز استفاده
1. اپ را باز کنید و با اکانت فایرفاکس وارد شوید.
2. لوکیشن را انتخاب کنید (یا همان *Recommended Location*).
3. دکمهٔ اتصال را بزنید:
   - **پروکسی سیستمی** (پیش‌فرض): ترافیک کروم، اج، سافاری و فایرفاکس
     خودکار از تونل رد می‌شود.
     - **ویندوز:** دو انتخاب در *تنظیمات → Traffic capture*:
     - **System proxy** — تنظیمات رجیستری سطح کاربر، بدون پرامپت ادمین؛
       مرورگرها و اپ‌های سازگار با WinINet از VPN رد می‌شوند.
     - **Full tunnel** — کل ترافیک سیستم (IPv4/IPv6) توسط یک آداپتور
       مجازی (sing-box TUN) گرفته می‌شود، دقیقاً مثل یک کلاینت VPN واقعی.
       در اولین اتصال یک بار UAC نشان داده می‌شود (ثبت Scheduled Task);
       بعد از آن همیشه بی‌صداست. اگر اپ کشته شود، هلپر تا ۳ دقیقه
       تونل را خودکار جمع می‌کند.
     - **مک:** در اولین اتصال یک بار رمز ادمین خواسته می‌شود (هلپر
       LaunchDaemon)؛ بعد از آن هرگز نمی‌پرسد.
   - **فقط پروکسی** (تنظیمات → Local proxy → Proxy-only mode): بدون هیچ
     تغییری در سیستم؛ اپ‌های موردنظر را به `SOCKS5 127.0.0.1:1080` وصل کنید.
4. تست: در مرورگر [ipify.org](https://ipify.org) را باز کنید — باید IP
   تونل را ببینید نه IP خودتان.

> **تلگرام دسکتاپ** عمداً پروکسی سیستمی مک را نمی‌خواند. در تلگرام:
> *Settings → Connection → Proxy → Add proxy → SOCKS5 با `127.0.0.1` و
> پورت `1080`* — در هر دو حالت کار می‌کند.

### استفاده روی آیفون یا آیپد
اپل ساخت تونل سراسری روی iOS را بدون اکانت پولی توسعه‌دهنده و entitlement
ویژهٔ VPN اجازه نمی‌دهد، پس فایل `.ipa` برای نصب وجود ندارد. به‌جای آن،
ولپاین تونلی که خودش برقرار کرده را روی شبکهٔ محلی با گوشی به اشتراک
می‌گذارد:

1. در مک: *تنظیمات → Share with a phone* را روشن کنید. آدرس نشان‌داده‌شده
   (IP وای‌فای/لان مک و پورت `1081`) را یادداشت کنید.
2. مثل همیشه به VPN وصل شوید و مک را بیدار و روی همان وای‌فای نگه دارید.
3. در آیفون: *Settings → Wi‑Fi → (i)* کنار همان شبکه → **HTTP Proxy →
   Manual**؛ Server = آدرس مک، Port = `1081`، Authentication خاموش.
4. حالا سافاری و اپ‌هایی که پروکسی وای‌فای را رعایت می‌کنند از خروجی VPN
   عبور می‌کنند. بعد از قطع اتصال، پروکسی را دوباره **Off** کنید.

در *تنظیمات → Share with a phone → Address and steps* می‌توانید آدرس و
مراحل را با یک کلیک کپی کنید؛ همان‌جا فایل `.mobileconfig` هم خروجی گرفته
می‌شود، اما اپل آن پروفایل را فقط روی دستگاه‌های supervised (Configurator یا
MDM) اعمال می‌کند — روی آیفون شخصی همان مرحلهٔ ۳ روش رسمی است. این مسیر
فقط ترافیک همان شبکهٔ وای‌فای را می‌گیرد و به اینترنت دیتا کاری ندارد.

> اگر مک پیام firewall داد، **Allow** را بزنید، وگرنه گوشی به مک نمی‌رسد.

### داده‌ها و لاگ‌ها
- تنظیمات و توکن‌ها (مقادیر با AES-256-GCM رمزنگاری می‌شوند):
  `~/Library/Application Support/FoxyVPN/`
- لاگ هلپر: `~/Library/Application Support/FoxyVPN/helper/`
- لاگ داخل اپ: **تنظیمات → Logs** (کپی یا خروجی فایل)

### حذف کامل هلپر ادمین
بستن اپ، هلپر را حذف **نمی‌کند** (طراحی عمدی برای «یک‌بار برای همیشه»):
```bash
sudo launchctl bootout system/com.vauth.foxyvpn.helper
sudo rm /Library/LaunchDaemons/com.vauth.foxyvpn.helper.plist
```

### عیب‌یابی
| مشکل | راه‌حل |
|---|---|
| ترافیک مرورگر تغییر نمی‌کند | مطمئن شوید *Proxy-only mode* خاموش است، دوباره وصل شوید؛ `scutil --proxy` باید `SOCKSEnable : 1` نشان دهد |
| پیام «System proxy needs administrator access» | پرامپت ادمین رد شده — دوباره اتصال بزنید و تأیید کنید |
| آیکون قدیمی در Dock | `killall Dock` |
| سقف ۵۰ گیگ تمام شده | ماهانه ریست می‌شود؛ بعد از آن دوباره امتحان کنید |
| آیفون به پروکسی مشترک نمی‌رسد | دو دستگاه باید روی یک وای‌فای باشند، مک بیدار و متصل بماند، و در پیام firewall گزینهٔ **Allow** را بزنید؛ از یک دستگاه دیگر با `curl -x http://<mac-ip>:1081 https://ipify.org` مسیر را امتحان کنید |
| `.mobileconfig` نصب شد ولی چیزی تغییر نکرد | اپل این پروفایل را فقط روی دستگاه supervised اعمال می‌کند؛ روی آیفون شخصی دستی *Settings → Wi‑Fi → (i) → HTTP Proxy → Manual* را پر کنید |

### بیلد از سورس
```bash
git clone https://github.com/HELBOYCODER/VulpineVPN.git
cd VulpineVPN-mac
# فقط JDK 17+ و Gradle 8.10 لازم است (بدون Android SDK)
gradle packageDistributionForCurrentOS
# خروجی: build/compose/binaries/main/dmg/VulpineVPN-<version>.dmg
```
تست بی‌سر‌رابطه: `gradle connectTest` (با سشن ذخیره‌شده وصل می‌شود،
پروکسی سیستمی و IP خروجی را بررسی و سپس وضعیت را برمی‌گرداند).

### ساختار پورت
- `src/main/kotlin/compat/` — لایهٔ سازگاری مینیمال اندروید تا کد UI نسخهٔ
  اندروید **بدون تغییر** روی دسکتاپ کامپایل شود.
- موتور VPN (سرویس SOCKS5 لوکال، تونل HTTP/2 نتّی به لبهٔ Fastly، تمدید
  proxy-pass، جابه‌جایی edge، watchdog) همان کد JVM اصلی است.
- `vpn/http/LocalHttpProxyServer.kt` — پروکسی HTTP روی شبکهٔ محلی برای
  دستگاه‌هایی که SOCKS نمی‌فهمند (آیفون). جریان‌هایش را از همان
  `UpstreamSession` سرویس SOCKS5 رد می‌کند، پس خروجی گوشی با خروجی مک یکی
  است. `vpn/http/IosProfile.kt` فایل `.mobileconfig` را می‌سازد و
  `vpn/http/LanAddress.kt` آدرسی را پیدا می‌کند که گوشی واقعاً می‌تواند به آن
  برسد.
- `vpn/tun/MacHelper.kt` — هلپر LaunchDaemon فقط پروکسی سیستمی را روشن/خاموش
  می‌کند (یک‌بار اجازهٔ ادمین، بعد بی‌صدا).
- خودِ موتور هرگز پروکسی سیستمی‌ای که می‌سازد دنبال نمی‌کند (ProxySelector
  روی DIRECT قفل شده) تا ترافیک کنترلی حلقه نکند.
- حالت تونل کامل (TUN) در نسخهٔ 1.0.4-mac3 طبق درخواست حذف شد؛ مدل ترافیک
  فقط «پروکسی لوکال / پروکسی سیستمی» است.

## License
MIT — based on [Vauth/FoxyVPN](https://github.com/Vauth/FoxyVPN) (MIT).
