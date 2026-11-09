bool safeBrowserAudio({
  required String? surface,
  required bool canIdentify,
  required String? capturedHandle,
}) => surface == 'browser' && canIdentify && capturedHandle != 'shronshiki';
