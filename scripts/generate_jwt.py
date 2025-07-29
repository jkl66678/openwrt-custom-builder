import jwt
import time
import sys

def main():
    # 从命令行参数获取APP_ID和私钥路径
    app_id = sys.argv[1]
    key_path = sys.argv[2]
    
    # 读取私钥
    with open(key_path, 'r') as f:
        private_key = f.read()
    
    # 生成JWT
    iat = int(time.time())
    exp = iat + 600  # 10分钟有效期
    token = jwt.encode(
        {'iat': iat, 'exp': exp, 'iss': app_id},
        private_key,
        algorithm='RS256'
    )
    
    print(f"JWT={token}")

if __name__ == "__main__":
    main()
