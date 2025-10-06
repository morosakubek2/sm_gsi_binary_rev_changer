#!/usr/bin/env python3

import os
import sys
import argparse
from pathlib import Path
import json

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
            print(f"❌ Błąd: Nie znaleziono sekcji SignerVer02 w {file_path}")
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
    if not signer_data or len(signer_data) < 128:
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

def extract_parameters(image_path, output_json=None, output_signer_bin=None):
    """Główna funkcja wyodrębniająca parametry z obrazu."""
    print(f"📥 Wyodrębnianie parametrów z: {image_path}")

    pos, signer_data = find_signer_section(image_path)
    if not signer_data:
        print("❌ Nie znaleziono sekcji SignerVer02")
        return False

    metadata = parse_signer_section(signer_data)
    if not metadata:
        print("❌ Nie udało się sparsować sekcji SignerVer02")
        return False

    print("✅ Znaleziono sekcję SignerVer02:")
    for key, value in metadata.items():
        print(f"   {key}: {value}")

    # Zapisz metadane do JSON jeśli podano
    if output_json:
        try:
            output_dir = os.path.dirname(output_json)
            if output_dir and not os.path.exists(output_dir):
                os.makedirs(output_dir)
            with open(output_json, 'w') as f:
                json.dump(metadata, f, indent=2)
            print(f"💾 Zapisano metadane do: {output_json}")
        except Exception as e:
            print(f"❌ Błąd zapisu pliku JSON {output_json}: {e}")
            return False

    # Zapisz sekcję SignerVer02 do pliku binarnego jeśli podano
    if output_signer_bin:
        try:
            output_dir = os.path.dirname(output_signer_bin)
            if output_dir and not os.path.exists(output_dir):
                os.makedirs(output_dir)
            with open(output_signer_bin, 'wb') as f:
                f.write(signer_data)
            print(f"💾 Zapisano sekcję SignerVer02 do: {output_signer_bin} ({len(signer_data)} bajtów)")
        except Exception as e:
            print(f"❌ Błąd zapisu pliku binarnego {output_signer_bin}: {e}")
            return False

    return True

def main():
    parser = argparse.ArgumentParser(description='Wyodrębnij parametry z obrazu firmware')
    parser.add_argument('image', help='Obraz źródłowy (misc.bin, boot.img, etc.)')
    parser.add_argument('--output-json', help='Plik wyjściowy JSON z metadanymi')
    parser.add_argument('--output-signer', help='Plik wyjściowy z sekcją SignerVer02 (128 bajtów)')

    args = parser.parse_args()

    if not os.path.exists(args.image):
        print(f"❌ Obraz nie istnieje: {args.image}")
        return 1

    success = extract_parameters(args.image, args.output_json, args.output_signer)
    return 0 if success else 1

if __name__ == "__main__":
    sys.exit(main())
