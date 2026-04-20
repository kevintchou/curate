/**
 * Error handling utilities for Edge Functions
 */

import { corsHeaders } from "./cors.ts";
import { ErrorCodes, ErrorResponse } from "./types.ts";

/**
 * Create a standardized error response
 */
export function errorResponse(
  code: string,
  message: string,
  status: number,
  details?: unknown
): Response {
  const body: ErrorResponse = {
    error: {
      code,
      message,
      ...(details && Deno.env.get("ENVIRONMENT") !== "production"
        ? { details }
        : {}),
    },
  };

  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/**
 * Bad Request (400) - Invalid input from client
 */
export function badRequest(message: string, details?: unknown): Response {
  return errorResponse(ErrorCodes.INVALID_REQUEST, message, 400, details);
}

/**
 * Missing Field (400) - Required field not provided
 */
export function missingField(fieldName: string): Response {
  return errorResponse(
    ErrorCodes.MISSING_FIELD,
    `Missing required field: ${fieldName}`,
    400
  );
}

/**
 * Unauthorized (401) - Missing or invalid auth
 */
export function unauthorized(message = "Unauthorized"): Response {
  return errorResponse(ErrorCodes.UNAUTHORIZED, message, 401);
}

/**
 * Unprocessable (422) - LLM couldn't generate valid response
 */
export function unprocessable(message: string, details?: unknown): Response {
  return errorResponse(ErrorCodes.PARSE_ERROR, message, 422, details);
}

/**
 * Rate Limited (429)
 */
export function rateLimited(): Response {
  return errorResponse(
    ErrorCodes.RATE_LIMITED,
    "Too many requests. Please try again later.",
    429
  );
}

/**
 * LLM Error (502) - Error from LLM provider
 */
export function llmError(message: string, details?: unknown): Response {
  return errorResponse(ErrorCodes.LLM_ERROR, message, 502, details);
}

/**
 * Internal Server Error (500)
 */
export function internalError(message: string, details?: unknown): Response {
  return errorResponse(ErrorCodes.INTERNAL_ERROR, message, 500, details);
}

/**
 * Success response helper
 */
export function successResponse<T>(data: T): Response {
  return new Response(JSON.stringify(data), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
