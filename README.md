# Serverless Image Processor (S3 + Lambda + Pillow)

A serverless image processing pipeline. Uploading an image to S3 automatically triggers a Lambda function that generates multiple optimized variants and writes them to a separate output bucket. No server, no polling, no manual processing step.

## Architecture

![Architecture diagram](docs/architecture.png)

Upload → S3 event → Lambda (Pillow layer) → 5 variants written to the processed bucket.

## Components

| Resource | Purpose |
|---|---|
| Upload S3 bucket | Source bucket for original images |
| Processed S3 bucket | Destination bucket for generated variants |
| Lambda function | Runs the image processing logic |
| Lambda layer | Pillow 10.4.0, built for Amazon Linux via Docker |
| S3 event notification + Lambda permission | Triggers the function automatically on upload |

## Deployment

```bash
./scripts/deploy.sh
```

This builds the Pillow layer (via Docker), runs `terraform init/plan/apply`, and prints the created bucket names and function name at the end.

## Usage

**Upload an image:**
```bash
aws s3 cp my-photo.jpg s3://<upload-bucket-name>/
```

**List generated variants:**
```bash
aws s3 ls s3://<processed-bucket-name>/ --recursive
```

**Download a specific variant:**
```bash
aws s3 cp s3://<processed-bucket-name>/my-photo_compressed.jpg ./
```

## Generated Variants

Each upload produces 5 outputs:

1. **Compressed JPEG** (85% quality): balance of quality and size
2. **Low-quality JPEG** (60% quality): smallest file size
3. **WebP** (85% quality): modern format, better compression than JPEG at equivalent quality
4. **PNG**: lossless, largest file size
5. **Thumbnail** (200x200): small preview image

```
Original: photo.jpg (500 KB)
├── photo_compressed_abc123.jpg (120 KB)
├── photo_low_abc123.jpg (80 KB)
├── photo_webp_abc123.webp (95 KB)
├── photo_png_abc123.png (450 KB)
└── photo_thumbnail_abc123.jpg (15 KB)
```

## Configuration

**Lambda environment variables:**
- `PROCESSED_BUCKET`: destination bucket, injected automatically by Terraform
- `LOG_LEVEL`: logging verbosity (default: `INFO`)

**Supported formats:** JPG, JPEG, PNG, WebP, GIF, BMP in; JPEG, PNG, WebP out.

## Monitoring

```bash
# Tail Lambda logs
aws logs tail /aws/lambda/<lambda-function-name> --follow

# Invocation count over the last hour
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=<lambda-function-name> \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Sum
```

## Customization

**Change compression levels**: edit `lambda/lambda_function.py`:
```python
COMPRESSION_LEVELS = {
    'compressed': 85,
    'low': 60,
    'webp': 85,
}
```

**Change thumbnail size:**
```python
THUMBNAIL_SIZE = (200, 200)
```

**Add a new variant**: inside `create_variants()`:
```python
variants['your_variant'] = img.copy()
variants['your_variant'].save(buffer, format='JPEG', quality=75)
```

## Design Notes

**Why a Lambda layer instead of bundling Pillow directly:** Pillow contains compiled C extensions. A binary built with `pip install` on Windows or macOS won't run inside Lambda's Amazon Linux environment. `scripts/build_layer_docker.sh` compiles Pillow inside a Linux container (`--platform linux/amd64`) so the resulting layer is actually Lambda-compatible, regardless of what OS it's built on.

**Why two buckets instead of one:** keeps source and processed content clearly separated, avoids the event-loop risk of a bucket's own writes re-triggering its own Lambda function, and lets each bucket have independent lifecycle/retention rules later if needed.

**Why `aws_s3_bucket_notification` needs an explicit `depends_on`:** the S3-to-Lambda permission (`aws_lambda_permission`) and the event notification wiring are separate resources with no direct reference between them. Without `depends_on`, Terraform could create the notification before the permission exists, briefly leaving S3 configured to invoke a function it isn't yet allowed to call.

## Cost Estimate

Approximate monthly cost, based on AWS's published pricing:

- S3 storage: $0.023/GB (first 50 TB)
- Lambda: first 1M requests free, then $0.20/1M
- Lambda duration: first 400,000 GB-seconds free
- S3 requests: $0.0004 per 1,000 PUT requests

**1,000 images/month ≈ $0.50–$2.00**, driven mostly by Lambda duration and S3 storage of the 5 generated variants per image.

## Security

- All S3 buckets are private, with no public access
- IAM least privilege: the Lambda execution role only has access to the specific buckets it needs
- S3 access restricted to this specific Lambda function via a scoped `source_arn` condition on the invoke permission

## Known Limitations

- No frontend. Pure backend automation, driven entirely by the AWS CLI/SDK
- No VPC isolation configured by default
- Max image size is bounded by Lambda's allocated memory (1024 MB)
- Lambda timeout is fixed at 60 seconds (`terraform/main.tf`). Large images or additional variants may need this raised

## Cleanup

```bash
./scripts/destroy.sh
```

Empties both S3 buckets (including all object versions) and destroys all Terraform-managed resources.
