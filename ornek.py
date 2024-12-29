import pandas as pd
import numpy as np
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_squared_error, r2_score, mean_absolute_error
import xgboost as xgb
import joblib
import psycopg2

# Database Connection
conn = psycopg2.connect(
    host="localhost",
    database="postgres",
    user="postgres",
    password="12345"
)

# Fetch Data
query = """
    SELECT cb.starts_at, cb.ends_at, c.price, cs.id AS station_id, c.charging_speed, c.is_dc, cs.energy_type, cs.is_open_area, cs.score
    FROM charger_block cb
    JOIN chargers c ON cb.charger_id = c.id
    JOIN charging_stations cs ON c.station_id = cs.id
"""
data = pd.read_sql(query, conn)

# Preprocess Data
data['duration'] = (data['ends_at'] - data['starts_at']).dt.total_seconds() / 3600
data['hour'] = pd.to_datetime(data['starts_at']).dt.hour
data['day'] = pd.to_datetime(data['starts_at']).dt.dayofweek
data['month'] = pd.to_datetime(data['starts_at']).dt.month
data['is_weekend'] = data['day'].isin([5, 6]).astype(int)
data['hour_sin'] = np.sin(2 * np.pi * data['hour'] / 24)
data['hour_cos'] = np.cos(2 * np.pi * data['hour'] / 24)
data['day_sin'] = np.sin(2 * np.pi * data['day'] / 7)
data['day_cos'] = np.cos(2 * np.pi * data['day'] / 7)

# Feature Engineering
usage_counts = data.groupby('station_id').size().reset_index(name='usage_count')
data = data.merge(usage_counts, on='station_id', how='left')
data['popularity'] = data['score'] * data['usage_count']

# Features and Target
X = data[['station_id', 'price', 'charging_speed', 'is_dc', 'energy_type', 'is_open_area', 'score', 
          'hour_sin', 'hour_cos', 'day_sin', 'day_cos', 'month', 'is_weekend', 'usage_count', 'popularity']]
y = data['duration']

# Train-Test Split
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# Train XGBoost Model
model = xgb.XGBRegressor(
    objective='reg:squarederror',
    n_estimators=500,
    max_depth=12,
    learning_rate=0.03,
    colsample_bytree=0.8,
    subsample=0.8,
    random_state=42
)
model.fit(X_train, y_train)

# Evaluate
predictions = model.predict(X_test)
print("Mean Squared Error:", mean_squared_error(y_test, predictions))
print("R-squared:", r2_score(y_test, predictions))
print("Mean Absolute Error:", mean_absolute_error(y_test, predictions))

# Save Model
joblib.dump(model, "demand_forecasting_model_v4.pkl")
print("Final Model saved successfully!")

conn.close()
