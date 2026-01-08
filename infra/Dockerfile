FROM apache/airflow:2.9.3

# Switch to airflow user (pip allowed)
USER airflow

# Install Python packages inside Airflow's venv
COPY requirements.txt /requirements.txt
RUN pip install --no-cache-dir -r /requirements.txt

USER root
