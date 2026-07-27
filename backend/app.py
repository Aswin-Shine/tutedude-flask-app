from flask import Flask, request, jsonify
from flask_cors import CORS
from pymongo import MongoClient
import os

app = Flask(__name__)
# Enable Cross-Origin Resource Sharing so our Node app can make API requests
CORS(app)

# Fallback URI connection configuration
MONGO_URI = os.getenv("MONGO_URI", "mongodb+srv://ashwinsh91_db_user:NH56mlwbxJFyhORv@cluster0.9n2vi99.mongodb.net/tutedude?retryWrites=true&w=majority")

try:
    client = MongoClient(MONGO_URI)
    db = client['tutedude_devops']
    collection = db['submissions']
except Exception as e:
    print(f"Database Connection Failure: {e}")

@app.route('/api/submit', methods=['POST'])
def handle_submission():
    data = request.get_json()
    if not data:
        return jsonify({"success": False, "error": "No payload received"}), 400
        
    username = data.get('username')
    email = data.get('email')
    
    if not username or not email:
        return jsonify({"success": False, "error": "Missing required data fields"}), 400
        
    try:
        # Commit to MongoDB Atlas cluster 
        document = {"username": username, "email": email}
        collection.insert_one(document)
        return jsonify({"success": True, "message": "Data processed successfully"}), 200
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001)