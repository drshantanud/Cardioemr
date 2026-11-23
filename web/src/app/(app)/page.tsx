"use client";
import { useRouter } from "next/navigation";
import { useEffect } from "react";
import { Loading } from "@/components/ui";
import { homeFor } from "@/lib/roles";
import { useSession } from "@/lib/session";

export default function Home() {
  const { selection } = useSession();
  const router = useRouter();
  useEffect(() => router.replace(homeFor(selection?.role)), [selection, router]);
  return <Loading />;
}
