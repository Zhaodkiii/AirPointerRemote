import hashlib, socket, struct, subprocess, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.decrepit.ciphers.algorithms import TripleDES
for method in ['vnc','account']:
    with socket.socket() as s:
        s.bind(('127.0.0.1',0))
        s.listen()
        s.settimeout(15)
        p=subprocess.Popen([sys.argv[1],str(s.getsockname()[1]),method])
        c,_=s.accept()
        c.settimeout(15)
        f=c.makefile('rb')
        c.sendall(b'RFB 003.889\n')
        assert f.read(12)==b'RFB 003.008\n'
        c.sendall(bytes([2,30,2]))
        assert f.read(1)==bytes([2 if method=='vnc' else 30])
        if method=='vnc':
            challenge=bytes(range(16))
            c.sendall(challenge)
            key=bytes(int(f'{i:08b}'[::-1],2) for i in b'example\0')
            assert f.read(16)==Cipher(TripleDES(key*3),modes.ECB()).encryptor().update(challenge)
        else:
            prime=2**127-1
            exponent=359
            c.sendall(struct.pack('>HH',3,16)+prime.to_bytes(16,'big')+pow(3,exponent,prime).to_bytes(16,'big'))
            blob=f.read(128)
            peer=int.from_bytes(f.read(16),'big')
            key=hashlib.md5(pow(peer,exponent,prime).to_bytes(16,'big')).digest()
            plain=Cipher(algorithms.AES(key),modes.ECB()).decryptor().update(blob)
            assert plain.startswith(b'test\0') and plain[64:].startswith(b'example\0')
        c.sendall(bytes(4))
        assert f.read(1)==b'\x01'
        c.sendall(struct.pack('>HH',2,2)+bytes([32,24,0,1,0,255,0,255,0,255,16,8,0,0,0,0])+struct.pack('>I',4)+b'Test')
        # Wait for the client's first framebuffer request before delivering pixels.
        while True:
            kind = f.read(1)
            if kind == b'\x00':
                assert len(f.read(19)) == 19
            elif kind == b'\x02':
                _, count = struct.unpack('>BH', f.read(3))
                assert len(f.read(count * 4)) == count * 4
            elif kind == b'\x03':
                assert len(f.read(9)) == 9
                break
            else:
                raise AssertionError(kind)
        c.sendall(struct.pack('>BBHHHHHi',0,0,1,0,0,2,2,0)+bytes([255,0,0,0])*4)
        output=f.read()
        assert struct.pack('>BBHI', 4, 1, 0, 65) in output
        assert struct.pack('>BBHI', 4, 1, 0, 66) not in output
        # The direct swipe starts in the top-left pixel and moves upwards.
        for location in [(0, 0), (1, 1)]:
            assert output.count(struct.pack('>BBHH', 5, 16, *location)) == 2
        direct = [(1,0,1), (0,0,1), (4,0,1), (0,0,1), (1,0,1), (1,1,1), (0,1,1)]
        assert b''.join(struct.pack('>BBHH', 5, mask, x, y) for mask, x, y in direct) in output
        drag = [(0,0,0), (1,0,0), (1,1,1), (0,1,1), (4,1,1), (0,1,1), (8,1,1), (0,1,1)]
        assert b''.join(struct.pack('>BBHH', 5, mask, x, y) for mask, x, y in drag) in output
        chord = [(1, 0xffeb), (1, 0xff09), (0, 0xff09), (0, 0xffeb)]
        assert b''.join(struct.pack('>BBHI', 4, down, 0, key) for down, key in chord) in output
        assert p.wait()==0
        print(method,'verified')
