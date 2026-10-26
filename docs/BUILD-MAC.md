# ساختن و اجرای «کیلس» با Xcode روی مک

این راهنما برای روز و برای Claude است: از روی بکاپ، بدون GitHub Actions، برنامه را روی آیفون اجرا کن.

## محتوای بکاپ

| چیز | کجا |
|---|---|
| کل کد و تاریخچه، همه‌ی شاخه‌ها | `STTS.bundle` (یک git bundle) |
| مدل گفتار Koochik (۲۱۲ مگابایت) و چهار فایل کنارش (`tokens.json`، `preprocessor.json`، `mel_filters_slaney_80x257.json`، `manifest.json`) | release با برچسب `backup-2026-10-26` در github.com/nikpendar/STTS، و روی Hugging Face ([Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16](https://huggingface.co/Reza2kn/Shenava-Koochik-1.0-CoreML-iOS15-fp16)) |
| آخرین IPA ساخته‌شده (run 40342285504) | همان release |
| فونت IRANYekanX | فقط رمزشده: `fonts/AppFont.ttf.enc` |

**کلید فونت (`FONT_KEY`) در بکاپ نیست.** GitHub رازها را پس نمی‌دهد. اگر کلید را جایی نگه نداشته‌ای، فونت فقط از فایل اصلی فونت برمی‌گردد. بدون کلید، برنامه با فونت سیستم ساخته می‌شود و بقیه‌اش فرقی نمی‌کند.

## پیش‌نیازها

- Xcode نسخه‌ی 26 یا بالاتر، از App Store. با نسخه‌ی پایین‌تر، شیشه‌ی مایع (Liquid Glass) کشیدن انگشت ساخته نمی‌شود.
- Homebrew و `brew install openssl@3`، فقط برای باز کردن فونت.
- در Xcode: Settings > Accounts > یک Apple ID اضافه کن. حساب رایگان کافی است.
- روی آیفون: Settings > Privacy & Security > Developer Mode را روشن کن. این گزینه بعد از اولین وصل‌کردن به Xcode پیدا می‌شود.

## گام‌ها

1. بازگرداندن کد:
   ```sh
   git clone STTS.bundle stts
   cd stts
   git checkout main            # یا batch-1021c، شاخه‌ی کار
   git remote set-url origin https://github.com/nikpendar/STTS.git
   ```
2. آماده‌سازی مدل و فونت:
   ```sh
   FONT_KEY='کلید فونت' ./scripts/mac-setup.sh          # مدل جدا؛ یک بار در برنامه از Files وارد می‌شود
   FONT_KEY='کلید فونت' ./scripts/mac-setup.sh bundle   # مدل داخل برنامه؛ بدون وارد کردن، ۲۰۰ مگابایت بیشتر
   ```
   اگر Hugging Face در دسترس نباشد، اسکریپت فایل‌ها را از release بکاپ می‌گیرد.
3. `PersianSTT.xcodeproj` را با Xcode باز کن.
4. برای هر دو target، یعنی `PersianSTT` و `PersianSTTKeyboard`، در Signing & Capabilities:
   - گزینه‌ی Automatically manage signing روشن باشد؛
   - Team را تیم شخصی Apple ID بگذار.
5. اگر Xcode گفت شناسه‌ی بسته (Bundle Identifier) در دسترس نیست، شناسه‌ی برنامه را عوض کن، مثلاً `ir.nikpendar.PersianSTT2`. شناسه‌ی کیبورد باید همان باشد به‌اضافه‌ی `.Keyboard`.
6. نسخه‌ای را که با AltServer نصب شده از گوشی پاک کن. با امضای دیگر روی آن نصب نمی‌شود. با پاک‌شدن برنامه، مدل هم پاک می‌شود و باید دوباره وارد شود، مگر اینکه از حالت `bundle` استفاده کرده باشی.
7. بالای پنجره، scheme `PersianSTT` و آیفون وصل‌شده را انتخاب کن، سپس Run (⌘R).
8. روی آیفون، بار اول: Settings > General > VPN & Device Management > Apple ID خودت > Trust.
9. فعال‌کردن کیبورد: Settings > General > Keyboard > Keyboards > Add New Keyboard > کیلس، سپس Allow Full Access.
10. مدل (اگر حالت `bundle` نبود): فایل `build-model/Koochik.mlmodel` را به گوشی بفرست و از داخل برنامه وارد کن.

## محدودیت‌های حساب رایگان

- امضا پس از ۷ روز باطل می‌شود. Run دوباره در Xcode آن را تمدید می‌کند.
- حداکثر ۳ برنامه، و ۱۰ App ID در هر ۷ روز.
- App Groups ندارد. برنامه برای همین تنظیمات را از راه کلیپ‌بورد نام‌دار به کیبورد می‌دهد.

## فرق با بیلد GitHub

- مرحله‌ی «Copy App Font» در Xcode، اگر `build-font/AppFont.ttf` وجود داشته باشد، فونت را در برنامه و کیبورد می‌گذارد. در GitHub این فایل نیست و فونت هنگام بسته‌بندی IPA اضافه می‌شود.
- مخزن آموزش (`TRAINING_REPO`) در Xcode تنظیم نمی‌شود و برنامه پیش‌فرض خودش، `nikpendar/keyless-training`، را برمی‌دارد.
- ساخت از خط فرمان، بدون باز کردن Xcode:
  ```sh
  xcodebuild -project PersianSTT.xcodeproj -target PersianSTT -configuration Debug -sdk iphoneos \
    -allowProvisioningUpdates DEVELOPMENT_TEAM=<شناسه‌ی تیم> build
  xcrun devicectl list devices
  xcrun devicectl device install app --device <شناسه‌ی گوشی> build/Debug-iphoneos/PersianSTT.app
  ```

## یادداشت برای Claude

- `device_bash` روی مک یک ماشین لینوکسی است و Xcode را اجرا نمی‌کند. ساخت و اجرا باید از راه Terminal و Xcode خود مک انجام شود (computer use).
- فایل فونت باز‌شده (`build-font/`) و هر فایل `AppFont.ttf` هرگز نباید commit شود. مخزن عمومی است.
- قانون بیلد سر جایش است: push به `main` فقط با دستور صریح روز.
