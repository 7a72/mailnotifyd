curl -X POST http://localhost:8000/ \
  -H "Authorization: Bearer your-secret-token-here" \
  -H "Content-Type: application/json" \
  -d '{
    "context": {
        "stage": "DATA",
        "sasl": {
            "login": "user",
            "method": "plain"
        },
        "client": {
            "ip": "192.168.1.1",
            "port": 34567,
            "ptr": "mail.example.com",
            "ehlo": "mail.example.com",
            "activeConnections": 1
        },
        "tls": {
            "version": "1.3",
            "cipher": "TLS_AES_256_GCM_SHA384",
            "cipherBits": 256,
            "certIssuer": "Let'\''s Encrypt",
            "certSubject": "mail.example.com"
        },
        "server": {
            "name": "Stalwart",
            "port": 25,
            "ip": "192.168.2.2"
        },
        "queue": {
            "id": "1234567890"
        },
        "protocol": {
            "version": "1.0"
        }
    },
    "envelope": {
        "from": {
            "address": "john@example.com",
            "parameters": {
                "size": 12345
            }
        },
        "to": [
            {
                "address": "bill@foobar.com",
                "parameters": {
                    "orcpt": "rfc822; b@foobar.com"
                }
            },
            {
                "address": "jane@foobar.com",
                "parameters": null
            }
        ]
    },
    "message": {
        "headers": [
            ["From", "John Doe <john@example.com>"],
            ["To", "Bill <bill@foobar.com>, Jane <jane@foobar.com>"],
            ["Subject", "Hello, World!"]
        ],
        "serverHeaders": [
            ["Received", "from mail.example.com (mail.example.com [192.168.1.1]) by mail.foobar.com (Stalwart) with ESMTPS id 1234567890"]
        ],
        "contents": "Hello, World!\r\n",
        "size": 12345
    }
  }'
