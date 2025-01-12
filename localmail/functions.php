<?php
function LOGG($message) {
    global $log_file;
    $timestamp = date('Y-d-m H:i:s');
    $log_entry = "[$timestamp] $message\n";
    file_put_contents($log_file, $log_entry, FILE_APPEND);
}

function WhiteCheck($ip, $file_path) {
    if (!file_exists($file_path)) {
        return false;
    }
    $whitelist = file($file_path, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    return in_array($ip, $whitelist);
}
function MakeBackupList(){
	global $backup_list, $mail_lang;
	if($mail_lang == "EN") {
		$b_list="<p>List of your current local backup:</p>";
	} else {
		$b_list="<p>Список локальних бекапів:</p>";
	}
	$b_list .= "<ul>";
	$backupArray = explode(':', $backup_list);
	foreach ($backupArray as $backup) {
		$b_list .= "<li>$backup</li>"; 
	}
	$b_list .= "</ul>\n";
	return $b_list;
}
function InsertPayload(){
	global $mail_payload;
	$payloadArray = explode(':', $mail_payload);
	foreach ($payloadArray as $txt) {
		$payload_text .= "$txt<br>";
	}
	return $payload_text;
}
?>
