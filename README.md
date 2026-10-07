# PersianSTT: تبدیل آفلاین گفتار فارسی به متن روی آیفون

موتور: whisper.cpp با مدل Whisper کوانتیزه، زبان ثابت روی فارسی. پس از نصب، هیچ اتصال اینترنتی لازم نیست.

## پیش‌نیاز
- مک با Xcode 16 یا جدیدتر
- آیفون با iOS 17 یا بالاتر و کابل
- یک Apple ID (حساب رایگان کافی است)

## ساخت و اجرا
1. پوشه‌ی `persian-stt` را روی مک قرار دهید و در Terminal اجرا کنید:
   ```
   cd persian-stt
   ./setup.sh
   ```
   این اسکریپت `whisper.xcframework` و مدل `ggml-base-q5_1.bin` (حدود ۵۷ مگابایت) را دانلود می‌کند.
2. `PersianSTT.xcodeproj` را در Xcode باز کنید.
3. هدف PersianSTT > Signing & Capabilities:
   - Team: حساب Apple ID خودتان را انتخاب کنید.
   - Bundle Identifier: آن را یکتا کنید، مثلاً `com.yourname.PersianSTT`.
4. آیفون را وصل کنید، آن را به‌عنوان مقصد اجرا انتخاب کنید و Run (⌘R) را بزنید.
5. بار اول روی آیفون: Settings > Privacy & Security > Developer Mode را روشن کنید، و در Settings > General > VPN & Device Management به گواهی توسعه‌دهنده اعتماد کنید.

برای سرعت واقعی، در Product > Scheme > Edit Scheme > Run گزینه‌ی Build Configuration را روی Release بگذارید. در حالت Debug کد Swift بهینه نمی‌شود، ولی بیشتر محاسبات داخل whisper.xcframework انجام می‌شود که همیشه بهینه‌شده است.

با حساب رایگان، اپ پس از ۷ روز منقضی می‌شود و باید دوباره از Xcode اجرا شود.

## استفاده
- «ضبط صدا» را بزنید، صحبت کنید، و «توقف و تبدیل» را بزنید.
- «انتخاب فایل صوتی» هر فایل m4a/wav/mp3 را تبدیل می‌کند، مثلاً از Voice Memos که در Files ذخیره شده است.

## تغییر مدل
دقت مدل base برای فارسی متوسط است. برای دقت بیشتر:
```
./setup.sh small-q5_1            # حدود ۱۸۱ مگابایت
./setup.sh large-v3-turbo-q5_0   # حدود ۵۴۷ مگابایت، بهترین دقت، آیفون ۱۳ یا جدیدتر
```
اسکریپت مدل قبلی را حذف می‌کند. سپس در Xcode دوباره Run بزنید.

## ساختار
- `PersianSTT/WhisperContext.swift`: فراخوانی whisper.cpp با زبان `fa`
- `PersianSTT/AudioLoader.swift`: تبدیل هر فایل صوتی به PCM تک‌کاناله‌ی ۱۶ کیلوهرتز
- `PersianSTT/Transcriber.swift`: ضبط میکروفون و مدیریت وضعیت
- `PersianSTT/ContentView.swift`: رابط کاربری راست‌به‌چپ
- `PersianSTT/Models/`: فایل مدل `.bin` (توسط setup.sh پر می‌شود)
- `Frameworks/whisper.xcframework`: توسط setup.sh دانلود می‌شود
