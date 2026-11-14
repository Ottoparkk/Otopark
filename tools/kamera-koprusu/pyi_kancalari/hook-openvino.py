# -*- coding: utf-8 -*-
# PyInstaller kancası: OpenVINO (köprü 1.4.2, grafik işlemcisi).
#
# OpenVINO'nun kendi kancası yok: eklentilerini (GPU) çalışırken yükler,
# PyInstaller onları göremez. Seçim paketle.ov_toplanacaklar'da (test edilir):
# NPU, ONNX / IR dışındaki model okuyucuları, .lib ve debug dosyaları girmez;
# telemetri hiç girmez. Dosyalar komut satırına yazılmaz — ~950 dosya
# Windows'un komut satırı sınırını aşıyordu (WinError 206).
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from paketle import ov_toplanacaklar  # noqa: E402

datas, binaries, hiddenimports = ov_toplanacaklar()
