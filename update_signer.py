#!/usr/bin/env python3

import os
import sys
import argparse
import re
import struct

def find_signer_section(file_path):
    """Znajduje sekcję SignerVer02 w pliku i zwraca pozycję oraz 128 bajtów danych."""
    try:
        with open(file_path, 'rb') as f:
            data = f.read()

        if not data:
            print(f"❌ Błąd: Plik {file_path} jest pusty")
            return None, None

        signer_pattern = b'SignerVer02'
        start_pos = data.find(signer_pattern)

        if start_pos == -1:
            return None, None

        section_length = 128
        end_pos = start_pos + section_length

        if end_pos > len(data):
            print(f"❌ Błąd: Sekcja SignerVer02 w {file_path} jest za krótka (rozmiar pliku: {len(data)} bajtów)")
            return None, None

        signer_data = data[start_pos:end_pos]
        return start_pos, signer_data
    except Exception as e:
        print(f"❌ Błąd podczas odczytu {file_path}: {e}")
        return None, None

def parse_signer_section(signer_data):
    """Parsuje sekcję SignerVer02 i wyodrębnia metadane."""
    if not signer_data or len(signer_data) != 128:
        print(f"❌ Błąd: Sekcja SignerVer02 ma nieprawidłowy rozmiar ({len(signer_data)} bajtów, oczekiwano 128)")
        return None

    try:
        metadata = {}
        metadata['signer_version'] = signer_data[0:15].split(b'\x00')[0].decode('ascii', errors='ignore')
        metadata['number'] = signer_data[16:31].split(b'\x00')[0].decode('ascii', errors='ignore')
        metadata['device_model'] = signer_data[32:63].split(b'\x00')[0].decode('ascii', errors='ignore')
        metadata['date'] = signer_data[64:78].split(b'\x00')[0].decode('ascii', errors='ignore')
        metadata['software_model'] = signer_data[80:111].split(b'\x00')[0].decode('ascii', errors='ignore')
        metadata['software_version'] = signer_data[112:127].split(b'\x00')[0].decode('ascii', errors='ignore') or "<empty>"

        return metadata
    except Exception as e:
        print(f"❌ Błąd parsowania sekcji SignerVer02: {e}")
        return None

def replace_all_occurrences(data, old_model, new_model, file_path=''):
    """Zamienia wszystkie wystąpienia starego modelu na nowy w danych binarnych."""
    if not old_model or not new_model or old_model == new_model:
        print('⚠️ Brak zmian: stary i nowy model są takie same lub nie podano modeli')
        return data, 0

    replacements = [
        (old_model.encode('ascii'), new_model.encode('ascii'), 'ASCII'),
        (old_model.encode('utf-8'), new_model.encode('utf-8'), 'UTF-8'),
        (old_model.encode('utf-16le'), new_model.encode('utf-16le'), 'UTF-16 LE'),
        (old_model.encode('ascii') + b'\x00', new_model.encode('ascii') + b'\x00', 'ASCII + null'),
        (old_model.encode('utf-8') + b'\x00', new_model.encode('utf-8') + b'\x00', 'UTF-8 + null'),
    ]

    new_data = bytearray(data)
    total_replacements = 0

    for old_bytes, new_bytes, encoding in replacements:
        if len(old_bytes) != len(new_bytes):
            continue

        count = 0
        start = 0
        while True:
            pos = data.find(old_bytes, start)
            if pos == -1:
                break
            new_data[pos:pos + len(new_bytes)] = new_bytes
            count += 1
            start = pos + len(new_bytes)

        if count > 0:
            total_replacements += count
            print(f"   🔄 Podmieniono {count} wystąpień w enkodowaniu {encoding} ({len(old_bytes)} bajtów)")

    return bytes(new_data), total_replacements

def detect_device_models_in_file(file_path, preferred_model=None):
    """Wykrywa modele urządzeń w pliku."""
    try:
        with open(file_path, 'rb') as f:
            data = f.read()

        # Wzorzec dla modeli Samsunga (np. F711BXXS8HXF2)
        pattern = rb'[A-Z][0-9]{3}[A-Z]{2}[A-Z0-9]{6,12}'
        matches = re.findall(pattern, data)
        models = sorted(list(set(m.decode('ascii', errors='ignore') for m in matches if 10 <= len(m) <= 20)))

        # Pobierz model z sekcji SignerVer02
        pos, signer_data = find_signer_section(file_path)
        signer_model = None
        if signer_data:
            metadata = parse_signer_section(signer_data)
            if metadata and metadata['device_model']:
                signer_model = metadata['device_model']

        # Priorytetyzacja: najpierw preferred_model, potem model z SignerVer02, potem pierwszy z listy
        if preferred_model and preferred_model in models:
            print(f"[+] Wykryto preferowany model: {preferred_model}")
            return [preferred_model] + [m for m in models if m != preferred_model]
        elif signer_model and signer_model in models:
            print(f"[+] Wykryto model z SignerVer02: {signer_model}")
            return [signer_model] + [m for m in models if m != signer_model]
        elif models:
            print(f"[+] Wykryto pierwszy model z listy: {models[0]}")
            return models
        else:
            print(f"⚠️ Nie wykryto żadnych modeli w {file_path}")
            return []
    except Exception as e:
        print(f"❌ Błąd podczas wykrywania modeli w {file_path}: {e}")
        return []

def update_single_file(file_path, new_signer_data=None, new_device_model=None, old_device_model=None, preferred_model=None, experimental_model_replace=False):
    """Aktualizuje pojedynczy plik."""
    if not os.path.exists(file_path):
        print(f"❌ Błąd: Plik nie istnieje: {file_path}")
        return False

    print(f"🔧 Przetwarzanie: {file_path}")

    try:
        with open(file_path, 'rb') as f:
            old_data = f.read()

        new_data = bytearray(old_data)
        modifications = []

        # Podmiana sekcji SignerVer02
        old_pos, old_signer = find_signer_section(file_path)
        if old_signer and new_signer_data:
            if len(new_signer_data) != 128:
                print(f"❌ Błąd: Plik SignerVer02 ({len(new_signer_data)} bajtów) ma nieprawidłowy rozmiar (oczekiwano 128)")
                return False
            new_data[old_pos:old_pos + 128] = new_signer_data
            modifications.append(f"SignerVer02 na 0x{old_pos:06X}")

        # Podmiana modelu urządzenia (tylko jeśli włączono experimental-model-replace)
        if experimental_model_replace and old_device_model and new_device_model and old_device_model != new_device_model:
            print(f"[+] Podmieniam model: stary '{old_device_model}' na nowy '{new_device_model}'")
            new_data, total_replacements = replace_all_occurrences(new_data, old_device_model, new_device_model, file_path)
            if total_replacements > 0:
                modifications.append(f"model {total_replacements}x")

        # Zapisz zmiany tylko jeśli były modyfikacje
        if modifications:
            with open(file_path, 'wb') as f:
                f.write(new_data)
            print(f"  ✅ Zaktualizowano: {', '.join(modifications)}")
            return True
        else:
            print('  ⚠️ Brak zmian potrzebnych')
            return False
    except Exception as e:
        print(f"  ❌ Błąd podczas przetwarzania {file_path}: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description='Aktualizuj sekcję SignerVer02 i model urządzenia w plikach firmware')
    parser.add_argument('command', choices=['update-file'], help='Komenda (update-file)')
    parser.add_argument('file', help='Plik do aktualizacji (np. boot.img)')
    parser.add_argument('--signer-section', help='Plik z nową sekcją SignerVer02 (128 bajtów)')
    parser.add_argument('--new-model', help='Nowy model urządzenia (np. F711BXXSFJYGB)')
    parser.add_argument('--old-model', help='Stary model urządzenia (np. F711BXXS8HXF2)')
    parser.add_argument('--preferred-model', help='Preferowany stary model urządzenia (np. F711BXXS8HXF2)')
    parser.add_argument('--auto-detect-old-model', action='store_true', help='Automatycznie wykryj stary model w pliku')
    parser.add_argument('--experimental-model-replace', action='store_true', help='Włącz eksperymentalną podmianę modelu poza SignerVer02')

    args = parser.parse_args()

    if args.command == 'update-file':
        if not args.signer_section and not args.new_model:
            print("❌ Błąd: Musisz podać --signer-section, --new-model lub oba")
            return 1

        new_signer_data = None
        if args.signer_section:
            try:
                with open(args.signer_section, 'rb') as f:
                    new_signer_data = f.read()
                if len(new_signer_data) != 128:
                    print(f"❌ Błąd: Plik {args.signer_section} ma nieprawidłowy rozmiar ({len(new_signer_data)} bajtów, oczekiwano 128)")
                    return 1
            except Exception as e:
                print(f"❌ Błąd odczytu {args.signer_section}: {e}")
                return 1

        old_model = args.old_model
        if args.auto_detect_old_model and not old_model:
            models = detect_device_models_in_file(args.file, args.preferred_model)
            if models:
                old_model = models[0]
            else:
                old_model = None

        success = update_single_file(args.file, new_signer_data, args.new_model, old_model, args.preferred_model, args.experimental_model_replace)
        return 0 if success else 1

if __name__ == "__main__":
    sys.exit(main())
