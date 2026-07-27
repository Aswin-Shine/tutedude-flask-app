const express = require('express');
const axios = require('axios');
const path = require('path');

const app = express();
const PORT = 3000;

// Target the backend container service using internal Docker Compose DNS routing
const BACKEND_URL = process.env.BACKEND_URL || 'http://backend:5001/api/submit';

app.use(express.urlencoded({ extended: true }));
app.use(express.json());

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// Render initial user submission viewport
app.get('/', (req, res) => {
  res.render('form', { error: null });
});

// Capture Form submission action and route via axios to the Flask worker container
app.post('/submit', async (req, res) => {
  const { username, email } = req.body;

  try {
    const response = await axios.post(BACKEND_URL, { username, email });

    if (response.data.success) {
      res.send("<h1>Data submitted successfully</h1>");
    } else {
      res.render('form', { error: response.data.error || "Execution fault." });
    }
  } catch (err) {
    // Render failure state inside current client frame without redirecting
    const errMessage = err.response?.data?.error || err.message;
    res.render('form', { error: `Backend Unreachable: ${errMessage}` });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Frontend service listening on port ${PORT}`);
});