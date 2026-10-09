# PersianSTT: تبدیل آفلاین گفتار فارسی به متن روی آیفون

موتور: whisper.cpp روی CPU، زبان ثابت روی فارسی. پس از نصب، هیچ اتصال اینترنتی لازم نیست.

مدل پیش‌فرض: `farbodbij/whisper-medium-Persian` با کوانتیزه‌ی q4_0 (۴۴۴ مگابایت، IPA حدود ۳۹۳ مگابایت).
خطای کلمه روی FLEURS فارسی ۱۱.۳٪ و روی Common Voice ۲۰.۲٪، در برابر ۲۰.۶٪ و ۴۶.۱٪ برای large-v3-turbo معمولی.

## ساخت
نیازی به Xcode نیست. هر push به `main` در GitHub Actions یک `PersianSTT.ipa` امضانشده می‌سازد
(`.github/workflows/build.yml`). فایل را از بخش Artifacts همان اجرا دانلود و از zip خارج کنید.

ورودی‌های اجرای دستی:
- `hf`: مدل fine-tune شده از Hugging Face که تبدیل و داخل برنامه قرار می‌گیرد؛ `none` یعنی از `model` استفاده شود.
- `quant`: نوع کوانتیزه برای مدل Hugging Face (پیش‌فرض q4_0).
- `model`: مدل ggml رسمی whisper.cpp، وقتی `hf=none` باشد.

## نصب روی آیفون
با AltServer (مک یا ویندوز) و Apple ID رایگان:
1. AltServer را از altstore.io نصب کنید و AltStore را روی گوشی نصب کنید.
2. گوشی را وصل کنید، Option را نگه دارید، روی آیکون AltServer کلیک کنید و Sideload .ipa… را بزنید.
3. هر ۷ روز در AltStore گزینه‌ی Refresh All را بزنید.

Sideloadly مناسب نیست: با Apple ID رایگان، اکستنشن کیبورد را با پروفایل خود برنامه امضا می‌کند و iOS آن را
هنگام اجرا می‌بندد (AMFI: has entitlements but is not a main binary).

## استفاده
- در برنامه: «ضبط صدا» یا «انتخاب فایل صوتی». متن خودکار کپی می‌شود.
- کیبورد «دیکته‌ی فارسی»: در Settings > General > Keyboard > Keyboards اضافه کنید و Full Access را روشن کنید.
  در برنامه «شروع جلسه‌ی کیبورد» را بزنید؛ سپس در هر برنامه‌ای با میکروفون کیبورد دیکته کنید.

## ساختار
- `PersianSTT/WhisperContext.swift`: فراخوانی whisper.cpp، لغو تبدیل، کوتاه کردن پنجره‌ی صدا (حداقل ۲۰ ثانیه برای مدل‌های fine-tune)
- `PersianSTT/Transcriber.swift`: ضبط و تبدیل داخل برنامه
- `PersianSTT/KeyboardSession.swift`: جلسه‌ی میکروفون پس‌زمینه برای کیبورد
- `PersianSTTKeyboard/KeyboardViewController.swift`: کیبورد فارسی با دکمه‌ی میکروفون
- `Shared/DictationBridge.swift`: ارتباط کیبورد و برنامه؛ فرمان‌ها با Darwin notification و متن از راه سوکت 127.0.0.1
  (برنامه‌ی پس‌زمینه نمی‌تواند در کلیپ‌بورد بنویسد و App Group با حساب رایگان در دسترس نیست)
- `.github/workflows/benchmark.yml` و `scripts/wer.py`: سنجش WER مدل‌ها روی FLEURS و Common Voice
- `.github/workflows/keyboard-test.yml`: اجرای کیبورد در شبیه‌ساز و ثبت لاگ
