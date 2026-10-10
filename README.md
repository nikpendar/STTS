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
کیبورد «دیکته‌ی فارسی» را در Settings > General > Keyboard > Keyboards اضافه کنید و Full Access را روشن کنید.
در برنامه «شروع جلسه» را بزنید؛ سپس در هر برنامه‌ای با میکروفون کیبورد دیکته کنید. خود برنامه صفحه‌ی تنظیمات کیبورد است.

## یادگیری از اصلاح‌ها (سرور روی Mac)
وقتی متن دیکته‌شده را با تایپ یا دیکته‌ی دوباره اصلاح کنید، کیبورد متن اصلاح‌شده را به برنامه می‌دهد و برنامه صدای همان
دیکته را با متن درست به سرور خودتان می‌فرستد. سرور مدل را با همه‌ی نمونه‌ها آموزش می‌دهد (LoRA روی مدل اصلی) و نسخه‌ی
جدید را فقط وقتی منتشر می‌کند که روی یک‌دهم کنارگذاشته‌ی نمونه‌ها خطای کلمه‌ی کمتری داشته باشد. برنامه نسخه‌ی جدید را
دستی یا خودکار دانلود می‌کند و به جای مدل داخلی به کار می‌برد.

راه‌اندازی روی Mac با Apple Silicon (حداقل ۱۶ گیگابایت RAM برای مدل medium):
1. یک بار: `xcode-select --install` و `brew install cmake`، سپس در پوشه‌ی مخزن `bash server/setup.sh`
   (بسته‌های پایتون، whisper.cpp برای تبدیل و کوانتیزه، و دانلود مدل پایه).
2. هر بار: `server/start.sh`. نشانی سرور در خروجی چاپ می‌شود، مثلاً `http://mac-mini.local:8765`.
3. در برنامه، بخش «یادگیری از اصلاح‌ها»: «ارسال اصلاح‌ها به سرور» را روشن کنید و همان نشانی را وارد کنید.
   گوشی و Mac باید در یک شبکه باشند؛ بار اول iOS اجازه‌ی دسترسی به شبکه‌ی محلی را می‌پرسد.

آموزش بعد از هر ۲۰ نمونه‌ی جدید خودکار شروع می‌شود (`--min-new`) یا با دکمه‌ی «شروع آموزش روی سرور». حداقل ۱۰ نمونه لازم است.
نمونه‌ها و مدل‌ها در `server/data` می‌مانند و گزارش آموزش در `server/data/train.log` است. دیکته‌های بلندتر از ۳۰ ثانیه
استفاده نمی‌شوند. گزینه‌های بیشتر: `server/start.sh --help` و `server/.venv/bin/python server/train.py --help`.

## ساختار
- `PersianSTT/WhisperContext.swift`: فراخوانی whisper.cpp، لغو تبدیل، کوتاه کردن پنجره‌ی صدا (حداقل ۲۰ ثانیه برای مدل‌های fine-tune)
- `PersianSTT/Transcriber.swift`: ضبط و تبدیل داخل برنامه
- `PersianSTT/KeyboardSession.swift`: جلسه‌ی میکروفون پس‌زمینه برای کیبورد
- `PersianSTTKeyboard/KeyboardViewController.swift`: کیبورد فارسی با دکمه‌ی میکروفون
- `PersianSTTKeyboard/EditTracker.swift`: تشخیص اصلاح متن دیکته‌شده
- `PersianSTT/PersonalModel.swift`: صف و ارسال اصلاح‌ها، دانلود و نصب مدل شخصی
- `server/`: سرور آموزش (`server.py`) و آموزش و انتشار مدل (`train.py`)؛ تست: `.github/workflows/training-test.yml`
- `Shared/DictationBridge.swift`: ارتباط کیبورد و برنامه؛ فرمان‌ها با Darwin notification و متن از راه سوکت 127.0.0.1
  (برنامه‌ی پس‌زمینه نمی‌تواند در کلیپ‌بورد بنویسد و App Group با حساب رایگان در دسترس نیست)
- `.github/workflows/benchmark.yml` و `scripts/wer.py`: سنجش WER مدل‌ها روی FLEURS و Common Voice
- `.github/workflows/keyboard-test.yml`: اجرای کیبورد در شبیه‌ساز و ثبت لاگ
