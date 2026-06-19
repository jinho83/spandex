import { initializeApp } from "firebase/app";
import { getFirestore } from "firebase/firestore";
import { getAuth } from "firebase/auth";

const firebaseConfig = {
  apiKey: "AIzaSyBhJcS6yaJa6y9s79h1phXE0efn73e6QaA",
  authDomain: "spandex-b19b4.firebaseapp.com",
  projectId: "spandex-b19b4",
  storageBucket: "spandex-b19b4.firebasestorage.app",
  messagingSenderId: "1001312758885",
  appId: "1:1001312758885:web:916e3b5790eded3d75ea8c"
};

const app = initializeApp(firebaseConfig);

export const db = getFirestore(app);
export const auth = getAuth(app);
