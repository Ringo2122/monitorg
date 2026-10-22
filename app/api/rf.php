<?php
header('X-Content-Type-Options: nosniff');
header('Cache-Control: no-store');

function out($code, $data) { http_response_code($code); header('Content-Type: application/json; charset=utf-8'); echo json_encode($data, JSON_UNESCAPED_UNICODE); exit; }
$cfg = @include __DIR__ . '/cfg.php';
if (!is_array($cfg) || empty($cfg['u']) || empty($cfg['k'])) out(503, ['error' => 'Хранилище файлов не настроено']);

$a = $_GET['a'] ?? '';
$r = $_GET['r'] ?? '';
if (!preg_match('/^\d{1,12}$/', $r)) out(400, ['error' => 'Нет номера отчёта']);
$base = preg_replace('~/www/.*$~', '', __DIR__) . '/report_files';
$dir = "$base/$r";

function sb($cfg, $path, $method, $hdrs) {
  $h = ['apikey: ' . $cfg['k'], 'Content-Type: application/json'];
  $auth = $_SERVER['HTTP_X_AUTH'] ?? '';
  $h[] = 'Authorization: Bearer ' . (preg_match('/^[\w.-]{20,4000}$/', $auth) ? $auth : $cfg['k']);
  foreach ($hdrs as $k) { $v = $_SERVER['HTTP_' . strtoupper(str_replace('-', '_', $k))] ?? ''; if ($v !== '' && preg_match('/^[\w.-]{8,200}$/', $v)) $h[] = "$k: $v"; }
  $c = curl_init($cfg['u'] . '/rest/v1/' . $path);
  curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 15, CURLOPT_HTTPHEADER => $h,
    CURLOPT_CUSTOMREQUEST => $method, CURLOPT_POSTFIELDS => $method === 'POST' ? '{}' : null]);
  $body = curl_exec($c); $code = curl_getinfo($c, CURLINFO_HTTP_CODE); curl_close($c);
  return $code >= 200 && $code < 300 ? json_decode($body, true) : null;
}
$isAdmin = fn() => !empty($_SERVER['HTTP_X_ADMIN_TOKEN']) && sb($cfg, 'rpc/is_admin', 'POST', ['x-admin-token']) === true;
$canRead = fn() => $isAdmin() || !empty(sb($cfg, 'reports?select=id&id=eq.' . $r, 'GET', ['x-user-token']));

function fname($n) {
  $n = basename(str_replace('\\', '/', (string)$n));
  $n = preg_replace('/[\x00-\x1f\x7f"<>|:*?]+/u', '_', $n);
  $n = ltrim(trim($n), '.');
  if (mb_strlen($n) > 120) { $e = pathinfo($n, PATHINFO_EXTENSION); $n = mb_substr($n, 0, 110) . ($e ? '.' . mb_substr($e, 0, 8) : ''); }
  return $n === '' ? 'file' : $n;
}

if ($a === 'ls') {
  if (!$canRead()) out(403, ['error' => 'Нет доступа']);
  $list = [];
  foreach (is_dir($dir) ? scandir($dir) : [] as $f) if ($f[0] !== '.' && is_file("$dir/$f")) $list[] = ['n' => $f, 's' => filesize("$dir/$f")];
  out(200, $list);
}
if ($a === 'dl') {
  $n = fname($_GET['n'] ?? '');
  if (!$canRead()) out(403, ['error' => 'Нет доступа']);
  $f = "$dir/$n";
  if (!is_file($f)) out(404, ['error' => 'Файл не найден']);
  header('Content-Type: application/octet-stream');
  header('Content-Length: ' . filesize($f));
  header("Content-Disposition: attachment; filename*=UTF-8''" . rawurlencode($n));
  readfile($f); exit;
}
if ($_SERVER['REQUEST_METHOD'] !== 'POST') out(405, ['error' => 'Нужен POST']);
if (!$isAdmin()) out(403, ['error' => 'Нет доступа']);

if ($a === 'up') {
  $n = fname($_GET['n'] ?? '');
  $o = (int)($_GET['o'] ?? 0);
  if (!is_dir($dir) && !mkdir($dir, 0700, true)) out(500, ['error' => 'Не создалась папка']);
  $part = "$dir/.part-" . md5($n);
  if ($o === 0) @unlink($part);
  clearstatcache();
  if ((is_file($part) ? filesize($part) : 0) !== $o) out(409, ['error' => 'Кусок не по порядку — загрузите файл заново']);
  $in = fopen('php://input', 'rb'); $fp = fopen($part, 'ab');
  if (!$in || !$fp) out(500, ['error' => 'Не записался файл']);
  stream_copy_to_stream($in, $fp); fclose($fp); fclose($in);
  if (!empty($_GET['last'])) {
    $final = "$dir/$n"; $i = 2;
    while (file_exists($final)) { $p = pathinfo($n); $final = "$dir/" . $p['filename'] . " ($i)" . (isset($p['extension']) ? '.' . $p['extension'] : ''); $i++; }
    rename($part, $final);
    out(200, ['n' => basename($final), 's' => filesize($final)]);
  }
  clearstatcache();
  out(200, ['o' => filesize($part)]);
}
if ($a === 'rm') {
  $files = isset($_GET['n']) ? [fname($_GET['n'])] : (is_dir($dir) ? array_diff(scandir($dir), ['.', '..']) : []);
  foreach ($files as $f) @unlink("$dir/$f");
  if (is_dir($dir) && count(scandir($dir)) === 2) @rmdir($dir);
  out(200, ['ok' => true]);
}
out(400, ['error' => 'Неизвестное действие']);
