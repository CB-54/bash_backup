<?php
use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\SMTP;
use PHPMailer\PHPMailer\Exception;
require 'config.php';
require 'functions.php';
require 'include/Exception.php';
require 'include/PHPMailer.php';
require 'include/SMTP.php';

$server = mysql_escape_string($_GET['server']);
$template = mysql_escape_string($_GET['temp']);
$mail_to = mysql_escape_string($_GET['mail']);
$backup_list = mysql_escape_string($_GET['list']);
$mail_lang = mysql_escape_string($_GET['lang']);
$get_ip = $_SERVER['REMOTE_ADDR'];
$errtext = mysql_escape_string($_GET['err']);
$mail_payload = mysql_escape_string($_GET['payload']);
if (empty($server) || empty($template) || empty($mail_to)) {
	LOGG("Some var were empty: S: $server T: $template M: $mail_to");
	exit;
}
if (empty($mail_lang)) {
	$mail_lang = "UA";
}
if (WhiteCheck($get_ip, $white_file)) {
	LOGG("Temp: $template");
	$temp_file = "templates/{$template}_{$mail_lang}.html";
	$temp_subfile = "templates/{$template}_{$mail_lang}_sub";
	if (!file_exists($temp_file) || !file_exists($temp_subfile)) {
		echo "Temp file or temp file sub doesnt exist: $temp_file $temp_subfile";
		LOGG("Temp file or temp file sub doesnt exist: $temp_file $temp_subfile");
		exit;
	}
	if ($mail_lang !== 'UA' && $mail_lang !== 'EN') {
		echo "Invalid language: $mail_lang";
		LOGG("Invalid language specified: $mail_lang");
		exit;
	}
	$mail_sub = file_get_contents($temp_subfile);
	try{
		LOGG("Trying send mail to $mail_to");
		$mail = new PHPMailer(true);
		$mail->CharSet = 'UTF-8';
		$mail->isSMTP();                                    
		$mail->Host       = "$mail_host";                    
		$mail->SMTPAuth   = true;                             
		$mail->Username   = "$mail_login";                     
		$mail->Password   = "$mail_password";                      
		$mail->SMTPSecure = $mail_secure; 
		$mail->Port       = $mail_port;  
		$mail->setFrom("$mail_login", "$mail_from");
		$mail->addAddress("$mail_to");               
		$mail->addReplyTo("support@example.ua", "Support example");

		$mail->isHTML(true);
		$mail->Subject = $mail_sub;
		if (!empty($mail_payload)) {
			$mail->Body = str_replace('HOSTNAMEREPLACE', "$server [$get_ip]", implode('', array_map('file_get_contents', ["templates/main_top_$mail_lang.html", $temp_file])) . InsertPayload() . file_get_contents("templates/main_bottom_$mail_lang.html"));
		} elseif ($template == "error") {	
			$mail->Body = str_replace('HOSTNAMEREPLACE', "$server [$get_ip]", implode('', array_map('file_get_contents', ["templates/main_top_$mail_lang.html", $temp_file])) . "<p>$errtext</p>"  . file_get_contents("templates/main_bottom_$mail_lang.html"));
		} elseif (empty($backup_list)) {
			$mail->Body = str_replace('HOSTNAMEREPLACE', "$server [$get_ip]", implode('', array_map('file_get_contents', ["templates/main_top_$mail_lang.html", $temp_file, "templates/main_bottom_$mail_lang.html"])));
		} else {
			$mail->Body = str_replace('HOSTNAMEREPLACE', "$server [$get_ip]", implode('', array_map('file_get_contents', ["templates/main_top_$mail_lang.html", $temp_file])) . MakeBackupList($backup_list) . file_get_contents("templates/main_bottom_$mail_lang.html"));
		}
		$mail->send();
#		echo $mail->Body;
		LOGG("Mail has been send to $mail_to Subject: $mail_sub Template: $template");
		echo "Mail has been send";
	}
	catch (Exception $e) {
		echo "Mailer Error: {$mail->ErrorInfo}";
		LOGG("Message could not be sent. Mailer Error: {$mail->ErrorInfo}");
	}

} else {
	echo "$get_ip not allowed to send mail here";
    LOGG("IP $get_ip is not whitelisted.");
}
?>
