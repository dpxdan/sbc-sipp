<?php
// worker_cps.php - contadores cumulativos de pernas criadas no FreeSWITCH, para o Zabbix (WEB-1437)
//
// Escuta CHANNEL_CREATE no event socket e grava em /dev/shm o total de pernas de entrada e de saida.
// O agent do Zabbix le os arquivos, e o item aplica "Change per second". Como so le eventos, nao
// altera chamadas, e o FreeSWITCH segue normal se este processo parar.
//
// So conta "Call-Direction" no inicio da linha: o evento traz tambem "Presence-Call-Direction",
// e um strpos em qualquer posicao contaria 2 por perna.
//
// Senha do event socket: /etc/fluxsbc/event_socket.pass (root, 0600), nunca neste arquivo.
// Variaveis so para testes: FLUXSBC_CPS_PASS_FILE, FLUXSBC_CPS_DIR, FLUXSBC_CPS_PORT.
// Codigos de saida: 3 senha ou autenticacao, 5 conexao ou gravacao. O systemd reinicia.

$host = '127.0.0.1';
$port = (int) (getenv('FLUXSBC_CPS_PORT') ?: 8021);
$pass_file = getenv('FLUXSBC_CPS_PASS_FILE') ?: '/etc/fluxsbc/event_socket.pass';
$dir = getenv('FLUXSBC_CPS_DIR') ?: '/dev/shm';
$inbound_file = $dir . '/fluxsbc_inbound_total';
$outbound_file = $dir . '/fluxsbc_outbound_total';

function fail($code, $message)
{
    fwrite(STDERR, "worker_cps: $message\n");
    exit($code);
}

// Retoma o total anterior: um restart do worker nao zera o contador
function read_counter($path)
{
    $value = is_readable($path) ? trim((string) file_get_contents($path)) : '';
    return ctype_digit($value) ? (int) $value : 0;
}

// Troca atomica: o cat do agent nunca le um valor pela metade
function write_counter($path, $value)
{
    $tmp = $path . '.tmp';
    if (file_put_contents($tmp, $value . "\n") === false || !rename($tmp, $path)) {
        fail(5, "falha ao gravar $path");
    }
}

// Le os cabecalhos de uma resposta do event socket ate a linha em branco
function read_headers($fp, $wait_s)
{
    $headers = [];
    $deadline = time() + $wait_s;
    while (time() <= $deadline) {
        $line = fgets($fp, 8192);
        if ($line === false) {
            if (feof($fp)) {
                break;
            }
            continue;
        }
        $line = rtrim($line, "\r\n");
        if ($line === '') {
            if ($headers) {
                return $headers;
            }
            continue;
        }
        $parts = explode(': ', $line, 2);
        $headers[$parts[0]] = isset($parts[1]) ? $parts[1] : '';
    }
    fail(5, 'event socket sem resposta');
}

function send_command($fp, $command)
{
    fwrite($fp, $command . "\n\n");
    $headers = read_headers($fp, 10);
    return isset($headers['Reply-Text']) ? $headers['Reply-Text'] : '';
}

$password = is_readable($pass_file) ? trim((string) file_get_contents($pass_file)) : '';
if ($password === '') {
    fail(3, "senha ausente ou ilegivel em $pass_file");
}

$fp = @fsockopen($host, $port, $errno, $errstr, 10);
if (!$fp) {
    fail(5, "conexao ao event socket falhou: $errstr ($errno)");
}
stream_set_timeout($fp, 1);

read_headers($fp, 10); // Content-Type: auth/request
if (strpos(send_command($fp, "auth $password"), '+OK') !== 0) {
    fail(3, 'event socket recusou a senha');
}
if (strpos(send_command($fp, 'event plain CHANNEL_CREATE'), '+OK') !== 0) {
    fail(5, 'event socket recusou a assinatura de CHANNEL_CREATE');
}

$inbound = read_counter($inbound_file);
$outbound = read_counter($outbound_file);
write_counter($inbound_file, $inbound);
write_counter($outbound_file, $outbound);
$written_inbound = $inbound;
$written_outbound = $outbound;
$last_write = time();
$partial = '';

while (true) {
    $chunk = fgets($fp, 8192);
    if ($chunk === false) {
        $meta = stream_get_meta_data($fp);
        if (empty($meta['timed_out'])) {
            break; // conexao encerrada
        }
    } else {
        // Timeout ou linha longa devolvem pedaco de linha: so conta a linha inteira
        $partial .= $chunk;
        if (substr($partial, -1) === "\n") {
            if (strpos($partial, 'Call-Direction: inbound') === 0) {
                $inbound++;
            } elseif (strpos($partial, 'Call-Direction: outbound') === 0) {
                $outbound++;
            }
            $partial = '';
        }
    }

    // No maximo uma gravacao por segundo, tambem quando o trafego para
    $now = time();
    if ($now > $last_write && ($inbound !== $written_inbound || $outbound !== $written_outbound)) {
        write_counter($inbound_file, $inbound);
        write_counter($outbound_file, $outbound);
        $written_inbound = $inbound;
        $written_outbound = $outbound;
        $last_write = $now;
    }
}

write_counter($inbound_file, $inbound);
write_counter($outbound_file, $outbound);
fclose($fp);
fail(5, 'event socket encerrou a conexao');
