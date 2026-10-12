| model | WER % | CER % | size MB | time / audio (4 CPU cores) |
|---|---|---|---|---|
| farbodbij-q4_1 | 19.6 | 3.9 | 492 | 3.955 |
| farbodbij-q4_0 | 20.0 | 4.3 | 444 | 2.155 |
| farbodbij-f16 | 20.2 | 4.0 | 1534 | 1.92 |
| farbodbij-q8_0 | 20.2 | 4.0 | 823 | 1.357 |
| farbodbij-q5_0 | 20.6 | 4.1 | 539 | 3.725 |
| farbodbij-q5_1 | 20.6 | 4.0 | 587 | 3.833 |

| model | spellings in the transcripts (reference in brackets) |
|---|---|
| farbodbij-q4_1 | arabic_letters 0 (1), arabic_digits 0 (0), latin_digits 0 (0), persian_digits 0 (0), zwnj 32 (0), mi_spaced 0 (7), ha_spaced 0 (1) |
| farbodbij-q4_0 | arabic_letters 0 (1), arabic_digits 0 (0), latin_digits 0 (0), persian_digits 0 (0), zwnj 33 (0), mi_spaced 0 (7), ha_spaced 0 (1) |
| farbodbij-f16 | arabic_letters 0 (1), arabic_digits 0 (0), latin_digits 0 (0), persian_digits 0 (0), zwnj 36 (0), mi_spaced 0 (7), ha_spaced 0 (1) |
| farbodbij-q8_0 | arabic_letters 0 (1), arabic_digits 0 (0), latin_digits 0 (0), persian_digits 0 (0), zwnj 36 (0), mi_spaced 0 (7), ha_spaced 0 (1) |
| farbodbij-q5_0 | arabic_letters 0 (1), arabic_digits 0 (0), latin_digits 0 (0), persian_digits 0 (0), zwnj 37 (0), mi_spaced 0 (7), ha_spaced 0 (1) |
| farbodbij-q5_1 | arabic_letters 0 (1), arabic_digits 0 (0), latin_digits 0 (0), persian_digits 0 (0), zwnj 37 (0), mi_spaced 0 (7), ha_spaced 0 (1) |

### farbodbij-q4_1
- ref: و کنار آبشار زندگی کنه
  hyp: و کنار آبشار زندگی کنه
- ref: زياد هم اهسته راه نرو
  hyp: زیاد هم آهسته راه نرو
- ref: یه زنه گفت یکم گرمه، کاش بخاری رو خاموش کنی
  hyp: یه زنه گفت یکم گرمه باید بخواهی را خموط کنیم

### farbodbij-q4_0
- ref: و کنار آبشار زندگی کنه
  hyp: و کنار آبشار زندگی کنه
- ref: زياد هم اهسته راه نرو
  hyp: زیاد هم آهسته راه نرو
- ref: یه زنه گفت یکم گرمه، کاش بخاری رو خاموش کنی
  hyp: یه زنگ گفت یکم گرمه باید بخواهی را خموش کنیم

### farbodbij-f16
- ref: و کنار آبشار زندگی کنه
  hyp: و کنار آبشار زندگی کنه
- ref: زياد هم اهسته راه نرو
  hyp: زیاد هم آهسته راه نرو
- ref: یه زنه گفت یکم گرمه، کاش بخاری رو خاموش کنی
  hyp: یه زنه گفت یکم گرمه باید بخواهی را خموش کنیم
