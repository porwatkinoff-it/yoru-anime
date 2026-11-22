use flate2::read::MultiGzDecoder;
use std::io::{self, Read};

const MAX_TEXT_BYTES: usize = 8 * 1024 * 1024;

pub fn decode(raw: &[u8]) -> io::Result<String> {
    if raw.len() > MAX_TEXT_BYTES {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "Текстовый файл слишком большой"));
    }
    // Видеосервер может отдать .ass в gzip. Проверяем по сигнатуре, чтобы читать и скачанные файлы.
    let mut unpacked = Vec::new();
    let bytes = if raw.starts_with(&[0x1f, 0x8b]) {
        MultiGzDecoder::new(raw)
            .take((MAX_TEXT_BYTES + 1) as u64)
            .read_to_end(&mut unpacked)?;
        if unpacked.len() > MAX_TEXT_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Текстовый файл слишком большой"));
        }
        unpacked.as_slice()
    } else {
        raw
    };

    if let Some((encoding, bom_length)) = encoding_rs::Encoding::for_bom(bytes) {
        return Ok(encoding.decode_without_bom_handling(&bytes[bom_length..]).0.into_owned());
    }
    Ok(match std::str::from_utf8(bytes) {
        Ok(text) => text.to_owned(),
        Err(_) => encoding_rs::WINDOWS_1251.decode(bytes).0.into_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{write::GzEncoder, Compression};
    use std::io::Write;

    fn gzip(bytes: &[u8]) -> Vec<u8> {
        let mut writer = GzEncoder::new(Vec::new(), Compression::fast());
        writer.write_all(bytes).unwrap();
        writer.finish().unwrap()
    }

    #[test]
    fn reads_plain_and_compressed_subtitles() {
        let subtitle = "[Events]\nDialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,Ёжик\n";
        assert_eq!(decode(subtitle.as_bytes()).unwrap(), subtitle);
        assert_eq!(decode(&gzip(subtitle.as_bytes())).unwrap(), subtitle);
        let (legacy, _, _) = encoding_rs::WINDOWS_1251.encode(subtitle);
        assert_eq!(decode(&gzip(&legacy)).unwrap(), subtitle);
    }

    #[test]
    fn rejects_truncated_and_oversized_gzip() {
        let mut compressed = gzip(b"WEBVTT");
        compressed.truncate(compressed.len() - 2);
        assert!(decode(&compressed).is_err());
        assert!(decode(&gzip(&vec![b'a'; MAX_TEXT_BYTES + 1])).is_err());
    }
}
