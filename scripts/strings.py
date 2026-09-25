#!/usr/bin/env python3
"""Добавляет или обновляет строки в String Catalog (.xcstrings) из TSV: ключ, en, ru.

    scripts/strings.py Shared/Resources/Localizable.xcstrings strings.tsv
    scripts/strings.py --check Shared/Resources/Localizable.xcstrings

TSV: строки «ключ<TAB>English<TAB>Русский[<TAB>комментарий]», пустые и начинающиеся с # пропускаются.
Множественное число: ключ с суффиксом «|plural», тогда en и ru — формы через « ¦ »:
  en «one ¦ other», ru «one ¦ few ¦ many ¦ other» (GLOSSARY §1.4).
--check: у каждой строки есть en и ru, иначе код выхода 1.
Каталог — источник правды: скрипт только сливает, ничего не удаляет.
"""
import json
import sys
from pathlib import Path

LANGS = ("en", "ru")


def load(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"sourceLanguage": "en", "strings": {}, "version": "1.0"}


def save(path: Path, catalog: dict) -> None:
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    path.write_text(text + "\n", encoding="utf-8")


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(forms: list, names: tuple) -> dict:
    return {"variations": {"plural": {name: unit(form) for name, form in zip(names, forms)}}}


def merge(catalog: dict, tsv: Path) -> int:
    count = 0
    for raw in tsv.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = raw.split("\t")
        if len(parts) < 3:
            sys.exit(f"строка без трёх колонок: {raw!r}")
        key, en, ru = parts[0].strip(), parts[1], parts[2]
        comment = parts[3].strip() if len(parts) > 3 else None
        entry = {"extractionState": "manual"}
        if key.endswith("|plural"):
            key = key[: -len("|plural")]
            en_forms = [f.strip() for f in en.split("¦")]
            ru_forms = [f.strip() for f in ru.split("¦")]
            if len(en_forms) != 2 or len(ru_forms) != 4:
                sys.exit(f"{key}: нужны 2 формы en и 4 формы ru")
            entry["localizations"] = {
                "en": plural(en_forms, ("one", "other")),
                "ru": plural(ru_forms, ("one", "few", "many", "other")),
            }
        else:
            entry["localizations"] = {"en": unit(en), "ru": unit(ru)}
        if comment:
            entry["comment"] = comment
        catalog["strings"][key] = entry
        count += 1
    return count


def check(catalog: dict) -> int:
    missing = [key for key, entry in catalog["strings"].items()
               if key and not all(lang in entry.get("localizations", {}) for lang in LANGS)]
    for key in missing:
        print(f"нет перевода: {key}")
    return 1 if missing else 0


def main() -> None:
    args = sys.argv[1:]
    if args and args[0] == "--check":
        sys.exit(check(load(Path(args[1]))))
    if len(args) != 2:
        sys.exit(__doc__)
    path, tsv = Path(args[0]), Path(args[1])
    catalog = load(path)
    added = merge(catalog, tsv)
    save(path, catalog)
    print(f"{path}: {added} строк")


if __name__ == "__main__":
    main()
