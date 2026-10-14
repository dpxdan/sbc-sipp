<?php
/*
 * Laboratorio STFC: imita o custo de uma pagina do FluxSBC (CodeIgniter 2).
 * Como o CI com sess_use_database = TRUE, cada request sem cookie cria uma
 * linha em flux.ci_sessions; com cookie valido, so le a sessao existente.
 * O banco e acessado pelo VIP do keepalived, como nos servidores de producao.
 */

$cfg = parse_ini_file('/etc/flux-lab/web-db.ini');
if ($cfg === false) {
    http_response_code(500);
    exit("configuracao do banco ausente\n");
}

mysqli_report(MYSQLI_REPORT_OFF);
$db = @new mysqli($cfg['host'], $cfg['user'], $cfg['password'], $cfg['database'], (int) $cfg['port']);
if ($db->connect_errno) {
    http_response_code(500);
    exit("falha no banco\n");
}

$ua  = substr(isset($_SERVER['HTTP_USER_AGENT']) ? $_SERVER['HTTP_USER_AGENT'] : '', 0, 120);
$ip  = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '0';
$sid = isset($_COOKIE['ci_session']) ? $_COOKIE['ci_session'] : '';
$valid = false;

if (preg_match('/^[a-f0-9]{32}$/', $sid)) {
    $st = $db->prepare('SELECT user_agent FROM ci_sessions WHERE session_id = ?');
    $st->bind_param('s', $sid);
    $st->execute();
    $st->bind_result($stored_ua);
    $valid = $st->fetch() && $stored_ua === $ua;
    $st->close();
}

if (!$valid) {
    $sid = bin2hex(random_bytes(16));
    $now = time();
    $st = $db->prepare('INSERT INTO ci_sessions (session_id, ip_address, user_agent, last_activity, user_data) VALUES (?, ?, ?, ?, \'\')');
    $st->bind_param('sssi', $sid, $ip, $ua, $now);
    $st->execute();
    $st->close();
    setcookie('ci_session', $sid, 0, '/');
}

$db->close();
header('Content-Type: text/html; charset=utf-8');
echo "<!doctype html><title>FluxSBC - Login (laboratorio)</title><p>login</p>\n";
