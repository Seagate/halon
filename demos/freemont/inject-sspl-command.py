#!/bin/python
import pika
import sys

def mk_msg(message):
   msg = ('{  "username": "sspl-ll"'
           ', "signature": "None"'
           ', "time": "2015-10-19 11:49:34.706694"'
           ', "message":{'
           '  "sspl_ll_msg_header":'
           '  { "schema_version": "1"'
           '  , "sspl_version": "0.15.2"'
           '  , "msg_version": "1"'
           '  , "uuid": "e50c300f-5540-453c-afa2-30a09c689952"}'
           '  , "sensor_response_type": { ' + message + '}}}')
   return msg;


msg_init = ('"disk_status_hpi":{"productName":"seagate-dh"'
            ',"enclosureSN":"enclosure1"'
            ',"drawer":1'
            ',"manufacturer":"seagate\"'
            ',"hostId":"devvm.seagate.com\"'
            ',"location":1'
            ',"deviceId":"loop1\"'
            ',"serialNumber":"serial1\"'
            ',"wwn":"wwn1"'
            ',"productVersion":"0.0.1"}')

msg_removal = ('"disk_status_drivemanager":{"serial_number":"serial1"'
               ',"status":"EMPTY"'
	       ',"disk":1"'
               ',"reason":"None"'
               ',"enclosure_serial_number":"enclosure1"}')

msg_insertion = ('"disk_status_drivemanager":{"serial_number":"serial1"'
                 ',"status":"OK"'
	         ',"disk":1'
                 ',"reason":"None"'
                 ',"enclosure_serial_number":"enclosure1"}')

def send(b):
        msg = mk_msg(b)
	connection = pika.BlockingConnection(pika.ConnectionParameters('localhost'))
	channel = connection.channel()
	channel.queue_declare(queue="dcs_queue", durable=False)
	channel.basic_publish( exchange="sspl_halon"
		             , routing_key="sspl_ll"
			     , body=msg);
	connection.close();
	print("send " + msg)


def main(action):
	if action == "init":
		send(msg_init);
	elif action == "remove":
		send(msg_removal);
	elif action == "insert":
		send(msg_insertion);
	else:
	     print("init|remove|insert")


if __name__ == "__main__":
	main(sys.argv[1]);	

