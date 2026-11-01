// Сетевые мелочи, которые на телефоне/ПК и в браузере устроены по-разному.
export 'platform_http_io.dart' if (dart.library.js_interop) 'platform_http_web.dart';
