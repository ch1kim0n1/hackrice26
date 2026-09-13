// Express 4 does not forward rejected promises from async handlers to the error
// middleware, so an unhandled rejection would hang the request. Wrap every async
// route handler with this so rejections reach the JSON error handler in index.ts.
// Required before porting any route from synchronous node:sqlite to async pg.
import { RequestHandler } from "express";

export function asyncHandler(fn: RequestHandler): RequestHandler {
  return (req, res, next) => {
    Promise.resolve(fn(req, res, next)).catch(next);
  };
}
