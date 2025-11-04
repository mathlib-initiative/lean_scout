from datasets import Dataset
import glob
import sys

def main():
    path = sys.argv[1]
    parquet_files = glob.glob(f"{path}/*.parquet")
    dataset = Dataset.from_parquet(parquet_files)
    for item in dataset:
        print(item)

if __name__ == "__main__":
    main()
